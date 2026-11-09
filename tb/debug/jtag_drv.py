"""Bit-banged JTAG host for cocotb, a reference TAP state model, the debug
transport scan helpers (the protocol in rtl/debug/README.md) and a Python
OBI slave memory with random grant and response latency.

TMS/TDI change while TCK is low; TDO is read just before the rising edge
(the TAP launches it on the falling edge).
"""

import random

from cocotb.triggers import FallingEdge, ReadOnly, Timer

# State codes as in jtag_tap.sv.
TLR, RTI, SELDR, CAPDR, SHDR, EX1DR, PADR, EX2DR, UPDR = 0xF, 0xC, 0x7, 0x6, 0x2, 0x1, 0x3, 0x0, 0x5
SELIR, CAPIR, SHIR, EX1IR, PAIR, EX2IR, UPIR = 0x4, 0xE, 0xA, 0x9, 0xB, 0x8, 0xD
NEXT = {  # state: (next if TMS=0, next if TMS=1), IEEE 1149.1 figure 6-1
    TLR: (RTI, TLR), RTI: (RTI, SELDR), SELDR: (CAPDR, SELIR), CAPDR: (SHDR, EX1DR),
    SHDR: (SHDR, EX1DR), EX1DR: (PADR, UPDR), PADR: (PADR, EX2DR), EX2DR: (SHDR, UPDR),
    UPDR: (RTI, SELDR), SELIR: (CAPIR, TLR), CAPIR: (SHIR, EX1IR), SHIR: (SHIR, EX1IR),
    EX1IR: (PAIR, UPIR), PAIR: (PAIR, EX2IR), EX2IR: (SHIR, UPIR), UPIR: (RTI, SELDR),
}
NAME = {TLR: "TLR", RTI: "RTI", SELDR: "SelDR", CAPDR: "CapDR", SHDR: "ShDR",
        EX1DR: "Ex1DR", PADR: "PauseDR", EX2DR: "Ex2DR", UPDR: "UpdDR", SELIR: "SelIR",
        CAPIR: "CapIR", SHIR: "ShIR", EX1IR: "Ex1IR", PAIR: "PauseIR", EX2IR: "Ex2IR",
        UPIR: "UpdIR"}

IR_LEN = 5
IR_IDCODE, IR_DBG, IR_BYPASS = 0x01, 0x18, 0x1F
IDCODE = 0x10502001
OP_NOP, OP_READ, OP_WRITE, OP_STATUS = range(4)
ST_OK, ST_ERR, ST_BUSY = 0, 2, 3
DR_LEN = 66


def val(sig):
    return int(sig.value)


def dr_word(op, addr=0, data=0):
    return (addr << 34) | (data << 2) | op


def dr_fields(word):
    """(status, data, addr) of a captured debug DR."""
    return word & 3, (word >> 2) & 0xFFFFFFFF, (word >> 34) & 0xFFFFFFFF


class Jtag:
    def __init__(self, dut, period_ps):
        self.dut = dut
        self.half = period_ps // 2
        self.state = None  # model state; None until a reset is known
        self.trace = []    # (state before edge, tms)
        dut.tck.value = 0
        dut.tms.value = 1
        dut.tdi.value = 0

    async def clock(self, tms, tdi=0):
        d = self.dut
        d.tms.value = tms
        d.tdi.value = tdi
        await Timer(self.half, unit="ps")
        tdo = val(d.tdo)
        if self.state is not None:
            self.trace.append((self.state, tms))
            self.state = NEXT[self.state][tms]
        d.tck.value = 1
        await Timer(self.half, unit="ps")
        d.tck.value = 0
        return tdo

    async def idle(self, n):
        for _ in range(n):
            await self.clock(0)

    async def reset(self):
        """Five TMS=1 reach Test-Logic-Reset from any state; then go to RTI."""
        for _ in range(5):
            await self.clock(1)
        self.state = TLR
        await self.clock(0)

    async def _shift(self, value, n):
        out = 0
        for i in range(n):
            out |= await self.clock(int(i == n - 1), value >> i & 1) << i
        await self.clock(1)  # Exit1 -> Update
        await self.clock(0)  # -> Run-Test/Idle
        return out

    async def ir(self, value):
        assert self.state == RTI
        for t in (1, 1, 0, 0):
            await self.clock(t)
        return await self._shift(value, IR_LEN)

    async def dr(self, value, n, idle=0):
        assert self.state == RTI
        for t in (1, 0, 0):
            await self.clock(t)
        out = await self._shift(value, n)
        await self.idle(idle)
        return out

    # ---- debug transport (rtl/debug/README.md)
    async def dbg_scan(self, op, addr=0, data=0, idle=8):
        return dr_fields(await self.dr(dr_word(op, addr, data), DR_LEN, idle))

    async def dbg_poll(self, idle=8, limit=2000):
        """NOP scans until not busy; returns (status, data, addr), busy scan count."""
        for n in range(limit):
            st, data, addr = await self.dbg_scan(OP_NOP, idle=idle)
            if st != ST_BUSY:
                return (st, data, addr), n
        raise AssertionError("debug transport stuck busy")

    async def dbg_write(self, addr, data, idle=8):
        await self.dbg_scan(OP_WRITE, addr, data, idle)
        (st, _, a), _ = await self.dbg_poll(idle)
        return st, a

    async def dbg_read(self, addr, idle=8):
        await self.dbg_scan(OP_READ, addr, 0, idle)
        (st, data, a), _ = await self.dbg_poll(idle)
        return st, data, a


class ObiMemory:
    """OBI slave on obi_*: gnt with probability p_gnt, rvalid 1+min_lat to
    1+max_lat cycles after the handshake. log: (we, addr, wdata, be) per transfer."""

    def __init__(self, dut, seed=1, p_gnt=0.5, max_lat=6, min_lat=0):
        self.dut = dut
        self.rng = random.Random(seed)
        self.p_gnt = p_gnt
        self.max_lat = max_lat
        self.min_lat = min_lat
        self.mem = {}
        self.log = []

    def word(self, addr):
        return self.mem.get(addr, (addr * 0x9E3779B1 + 0x5A5A) & 0xFFFFFFFF)

    async def run(self):
        d = self.dut
        owed = None  # [cycles left, rdata]
        d.obi_gnt.value = 0
        d.obi_rvalid.value = 0
        d.obi_rdata.value = 0
        while True:
            await FallingEdge(d.clk)
            rvalid = owed is not None and owed[0] == 0
            if owed is not None and owed[0] > 0:
                owed[0] -= 1
            d.obi_rvalid.value = int(rvalid)
            d.obi_rdata.value = owed[1] if rvalid else self.rng.getrandbits(32)
            free = owed is None or rvalid
            # obi_req is a master flop, already settled at the falling edge.
            d.obi_gnt.value = int(free and val(d.obi_req) and self.rng.random() < self.p_gnt)
            await ReadOnly()
            if rvalid:
                owed = None
            if val(d.obi_req) and val(d.obi_gnt):
                addr, we = val(d.obi_addr), val(d.obi_we)
                wdata, be = val(d.obi_wdata), val(d.obi_be)
                self.log.append((we, addr, wdata, be))
                rdata = self.word(addr)
                if we:
                    self.mem[addr] = wdata
                owed = [self.rng.randint(self.min_lat, self.max_lat), rdata]
