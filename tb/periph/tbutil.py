"""Shared cocotb helpers: clock/reset, an APB4 master, an OBI master, an APB
slave model with scripted wait states, and the checker-quiet check.

Timing convention: every driver writes on the falling edge and samples in
ReadOnly of the same cycle; the handshake it observed takes effect at the
following rising edge. DUT outputs are registered or combinational from
registers and these drivers, so there is no zero-delay race between models.
"""

from collections import deque
import random

from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, ReadOnly, RisingEdge

CLK_NS = 10


def val(sig):
    """Integer value of a signal (raises if it holds X/Z)."""
    v = sig.value
    try:
        return v.to_unsigned()
    except AttributeError:
        return int(v)


async def start(dut, inputs_idle, rst_cycles=4):
    """Drive idle inputs, start the clock, apply and release reset."""
    for name, value in inputs_idle.items():
        getattr(dut, name).value = value
    dut.rst.value = 1
    Clock(dut.clk, CLK_NS, unit="ns").start()
    await ClockCycles(dut.clk, rst_cycles)
    await FallingEdge(dut.clk)
    dut.rst.value = 0


def assert_quiet(dut, checkers):
    """No rule of any listed checker has fired (sticky bits in the checker)."""
    for name in checkers:
        fired = val(getattr(dut, name).fired)
        assert fired == 0, f"checker {name} fired rules mask {fired:#x}"


APB_IDLE = {"psel": 0, "penable": 0, "pwrite": 0, "paddr": 0, "pwdata": 0, "pstrb": 0,
            "pprot": 0}


def lane_mask(strb):
    """32-bit mask of the byte lanes enabled in a 4-bit strobe."""
    return sum(0xFF << (8 * i) for i in range(4) if strb >> i & 1)


class ApbMaster:
    """APB4 master for a single slave: SETUP, ACCESS until pready, then idle.
    pstrb defaults to 0xF on writes and is 0 on reads; pprot is 0."""

    def __init__(self, dut):
        self.dut = dut

    def idle(self):
        for k, v in APB_IDLE.items():
            getattr(self.dut, k).value = v

    async def xfer(self, addr, write, data=0, strb=0xF, max_wait=64):
        d = self.dut
        await FallingEdge(d.clk)
        d.psel.value = 1
        d.penable.value = 0
        d.paddr.value = addr
        d.pwrite.value = int(write)
        d.pwdata.value = data
        d.pstrb.value = strb if write else 0
        d.pprot.value = 0
        await FallingEdge(d.clk)
        d.penable.value = 1
        rdata = None
        for _ in range(max_wait):
            await ReadOnly()
            if val(d.pready):
                rdata = val(d.prdata)
                break
            await FallingEdge(d.clk)
        else:
            raise AssertionError(f"APB pready timeout at {addr:#x}")
        await FallingEdge(d.clk)
        d.psel.value = 0
        d.penable.value = 0
        d.pstrb.value = 0
        return rdata

    async def write(self, addr, data, strb=0xF):
        await self.xfer(addr, True, data, strb)

    async def read(self, addr):
        return await self.xfer(addr, False)


class ObiMaster:
    """OBI master. Presents the next request as soon as the previous one is
    granted (the slave enforces one outstanding), optionally with random idle
    cycles, and drives random values on the bus while req is low."""

    def __init__(self, dut, prefix="", read_only=False, seed=1):
        self.clk = dut.clk
        self.req = getattr(dut, prefix + "req")
        self.gnt = getattr(dut, prefix + "gnt")
        self.addr = getattr(dut, prefix + "addr")
        self.rvalid = getattr(dut, prefix + "rvalid")
        self.rdata = getattr(dut, prefix + "rdata")
        self.read_only = read_only
        if not read_only:
            self.we = getattr(dut, prefix + "we")
            self.be = getattr(dut, prefix + "be")
            self.wdata = getattr(dut, prefix + "wdata")
        self.rng = random.Random(seed)
        self.cycles = 0

    def _drive(self, req, addr, we=0, be=0xF, wdata=0):
        self.req.value = req
        self.addr.value = addr
        if not self.read_only:
            self.we.value = we
            self.be.value = be
            self.wdata.value = wdata

    def idle(self):
        self._drive(0, 0)

    def _garbage(self):
        r = self.rng
        self._drive(0, r.getrandbits(32), r.getrandbits(1), r.getrandbits(4), r.getrandbits(32))

    async def run(self, txns, idle_prob=0.0, max_cycles=100000):
        """txns: list of (addr, we, be, wdata). Returns read data per txn
        (None for writes) in order; self.cycles is the cycle count."""
        results = []
        owed = deque()
        nxt = 0
        cur = None
        self.cycles = 0
        while len(results) < len(txns):
            await FallingEdge(self.clk)
            if cur is None and nxt < len(txns) and self.rng.random() >= idle_prob:
                cur = txns[nxt]
                self._drive(1, *cur)
            elif cur is None:
                self._garbage()
            await ReadOnly()
            if val(self.rvalid):
                assert owed, "rvalid with nothing owed"
                t = owed.popleft()
                results.append(None if t[1] else val(self.rdata))
            if cur is not None and val(self.gnt):
                owed.append(cur)
                nxt += 1
                cur = None
            self.cycles += 1
            assert self.cycles < max_cycles, "OBI master timeout"
        await FallingEdge(self.clk)
        self.idle()
        return results

    async def write(self, addr, data, be=0xF):
        await self.run([(addr, 1, be, data)])

    async def read(self, addr):
        return (await self.run([(addr, 0, 0xF, 0)]))[0]


class ApbSlaveModel:
    """16 APB slots on flat prdata[511:0] / pready[15:0]. waits[slot] is the
    number of ACCESS cycles with pready low before the completing one.
    Unselected slots drive random prdata to expose mux leaks."""

    def __init__(self, dut, waits=None, seed=2):
        self.dut = dut
        self.waits = waits if waits is not None else {}
        self.mem = {}
        self.log = []          # (slot, paddr, pwrite, data) per completed transfer
        self.strb_log = []     # (pstrb, pprot) per completed transfer
        self.access_cycles = []  # ACCESS cycles per completed transfer
        self.rng = random.Random(seed)

    def _data(self, slot, paddr):
        return self.mem.get((slot, paddr), (0xA5000000 | (slot << 16) | paddr))

    async def run(self):
        d = self.dut
        cnt = 0
        while True:
            await FallingEdge(d.clk)
            psel = val(d.psel)
            pen = val(d.penable)
            prdata = self.rng.getrandbits(512)
            pready = 0xFFFF
            if psel and pen:
                slot = psel.bit_length() - 1
                paddr = val(d.paddr)
                if cnt >= self.waits.get(slot, 0):
                    write = val(d.pwrite)
                    strb = val(d.pstrb)
                    data = val(d.pwdata) if write else self._data(slot, paddr)
                    if write:
                        m = lane_mask(strb)
                        old = self._data(slot, paddr)
                        self.mem[(slot, paddr)] = (old & ~m | data & m) & 0xFFFFFFFF
                    prdata &= ~(0xFFFFFFFF << (32 * slot))
                    prdata |= data << (32 * slot)
                    self.log.append((slot, paddr, write, data))
                    self.strb_log.append((strb, val(d.pprot)))
                    self.access_cycles.append(cnt + 1)
                    cnt = 0
                else:
                    pready &= ~(1 << slot)
                    cnt += 1
            else:
                cnt = 0
            d.prdata.value = prdata
            d.pready.value = pready


async def wait_cycles(dut, n):
    await ClockCycles(dut.clk, n)


async def rising(dut):
    await RisingEdge(dut.clk)
