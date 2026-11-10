"""axil_attn: AXI4-Lite protocol (random back-pressure on all five channels,
checked by a monitor), register map, and full attention runs compared with
p1 model/attn.py attn_fixed. The system clock is 10 ns; the accelerator
clock is ACCEL_PERIOD_PS with a random phase, so the two are unrelated.
"""
import os
import pathlib
import random
import sys

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

P1 = pathlib.Path(os.environ.get("P1_ROOT", pathlib.Path(__file__).resolve().parents[3] / "p1-attention"))
sys.path.insert(0, str(P1 / "model"))
import attn  # noqa: E402

ACCEL_PERIOD_PS = int(os.environ.get("ACCEL_PERIOD_PS", "13698"))
OKAY, SLVERR = 0, 2
CTRL, STATUS, LOAD, RD_ADDR, RD_DATA, CYCLES, IRQ, ID = range(0, 0x20, 4)
ID_VALUE = 0x4154544E
LUT = attn.gen_exp_lut()


def expected_cycles(n):
    nb = n // 4
    return nb * (16 * nb + 156) + 1


class Monitor:
    """AXI4-Lite rules, sampled at every falling edge (signals settled)."""

    CH = {"aw": ["awaddr", "awprot"], "w": ["wdata", "wstrb"], "b": ["bresp"],
          "ar": ["araddr", "arprot"], "r": ["rdata", "rresp"]}

    def __init__(self, dut):
        self.dut = dut
        self.hs = {c: 0 for c in self.CH}
        self.prev = None
        self.errors = []
        self.stalls = {c: 0 for c in self.CH}  # cycles with valid && !ready

    def sample(self):
        d = self.dut
        s = {}
        for c, fields in self.CH.items():
            s[c] = (int(getattr(d, c + "valid").value), int(getattr(d, c + "ready").value),
                    tuple(int(getattr(d, f).value) for f in fields))
        return s

    async def run(self):
        while True:
            await FallingEdge(self.dut.clk)
            if int(self.dut.rst.value):
                self.prev = None
                continue
            s = self.sample()
            if self.prev:
                for c in self.CH:
                    pv, pr, pp = self.prev[c]
                    if pv and not pr and (not s[c][0] or s[c][2] != pp):
                        self.errors.append(f"{c}: valid dropped or payload changed before ready")
            # A response needs its request(s) to have completed on an earlier edge.
            if self.hs["b"] + s["b"][0] > min(self.hs["aw"], self.hs["w"]):
                self.errors.append("b: response before both AW and W handshakes")
            if self.hs["r"] + s["r"][0] > self.hs["ar"]:
                self.errors.append("r: response before the AR handshake")
            for c in self.CH:
                if s[c][0] and s[c][1]:
                    self.hs[c] += 1
                elif s[c][0]:
                    self.stalls[c] += 1
            self.prev = s


class Master:
    """One write and one read may be in flight at once; random delays on
    every valid and ready this side drives."""

    def __init__(self, dut, rng, stall=0.5, maxwait=4):
        self.dut, self.rng, self.stall, self.maxwait = dut, rng, stall, maxwait

    async def _gap(self):
        if self.rng.random() < self.stall:
            for _ in range(self.rng.randint(1, self.maxwait)):
                await RisingEdge(self.dut.clk)

    async def _send(self, ch, fields):
        d = self.dut
        await self._gap()
        for name, val in fields.items():
            getattr(d, name).value = val
        getattr(d, ch + "valid").value = 1
        while True:
            await FallingEdge(d.clk)
            hs = int(getattr(d, ch + "ready").value)
            await RisingEdge(d.clk)
            if hs:
                getattr(d, ch + "valid").value = 0
                return

    async def _recv(self, ch, fields):
        d = self.dut
        while True:
            ready = 0 if self.rng.random() < self.stall else 1
            getattr(d, ch + "ready").value = ready
            await FallingEdge(d.clk)
            hs = ready and int(getattr(d, ch + "valid").value)
            vals = [int(getattr(d, f).value) for f in fields]
            await RisingEdge(d.clk)
            if hs:
                getattr(d, ch + "ready").value = 0
                return vals

    async def write(self, addr, data, strb=0xF):
        aw = cocotb.start_soon(self._send("aw", {"awaddr": addr, "awprot": 0}))
        w = cocotb.start_soon(self._send("w", {"wdata": data, "wstrb": strb}))
        (resp,) = await self._recv("b", ["bresp"])
        await aw
        await w
        return resp

    async def read(self, addr):
        await self._send("ar", {"araddr": addr, "arprot": 0})
        data, resp = await self._recv("r", ["rdata", "rresp"])
        return data, resp

    async def write_many(self, ops):
        """Issue AW and W for every (addr, data) without waiting for B, so a
        stalled B back-pressures AW and W; returns the bresp list in order."""
        async def aws():
            for a, _ in ops:
                await self._send("aw", {"awaddr": a, "awprot": 0})

        async def ws():
            for _, d in ops:
                await self._send("w", {"wdata": d, "wstrb": 0xF})
        t1, t2 = cocotb.start_soon(aws()), cocotb.start_soon(ws())
        resps = [(await self._recv("b", ["bresp"]))[0] for _ in ops]
        await t1
        await t2
        return resps

    async def read_many(self, addrs):
        """Issue every AR without waiting for R; returns [(rdata, rresp)]."""
        async def ars():
            for a in addrs:
                await self._send("ar", {"araddr": a, "arprot": 0})
        t = cocotb.start_soon(ars())
        out = [tuple(await self._recv("r", ["rdata", "rresp"])) for _ in addrs]
        await t
        return out


async def setup(dut, seed, stall=0.5):
    rng = random.Random(seed)
    for s in ["awvalid", "wvalid", "bready", "arvalid", "rready", "awaddr", "awprot",
              "wdata", "wstrb", "araddr", "arprot"]:
        getattr(dut, s).value = 0
    dut.rst.value = 1
    dut.accel_rst.value = 1
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await Timer(rng.randint(1, ACCEL_PERIOD_PS - 1), unit="ps")  # random phase
    cocotb.start_soon(Clock(dut.accel_clk, ACCEL_PERIOD_PS, unit="ps").start())
    for _ in range(4):
        await RisingEdge(dut.accel_clk)
    dut.accel_rst.value = 0
    await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)
    mon = Monitor(dut)
    cocotb.start_soon(mon.run())
    return Master(dut, rng, stall), mon, rng


def done_check(mon):
    assert not mon.errors, "AXI monitor: " + "; ".join(mon.errors[:5])


async def wr_ok(m, addr, data, strb=0xF):
    resp = await m.write(addr, data, strb)
    assert resp == OKAY, f"write {addr:#x} = {data:#x}: bresp {resp}"


async def rd_ok(m, addr):
    data, resp = await m.read(addr)
    assert resp == OKAY, f"read {addr:#x}: rresp {resp}"
    return data


@cocotb.test()
async def reset_values_and_id(dut):
    m, mon, _ = await setup(dut, 1, stall=0.0)
    assert await rd_ok(m, ID) == ID_VALUE
    assert await rd_ok(m, CTRL) == 4 << 8, "N_LEN resets to 4"
    for r in (STATUS, LOAD, RD_ADDR, RD_DATA, CYCLES, IRQ):
        assert await rd_ok(m, r) == 0, f"offset {r:#x} resets to 0"
    assert int(dut.irq.value) == 0
    done_check(mon)


@cocotb.test()
async def register_map(dut):
    m, mon, _ = await setup(dut, 2)
    # N_LEN is RW, byte lane 1 only; START reads 0
    await wr_ok(m, CTRL, 40 << 8)
    assert await rd_ok(m, CTRL) == 40 << 8
    await wr_ok(m, CTRL, 12 << 8, strb=0x1)
    assert await rd_ok(m, CTRL) == 40 << 8, "N_LEN changed without its strobe"
    # IRQ_EN is RW, DONE stays 0 (write-1-clear), BUSY / ACCEL_BUSY read-only
    await wr_ok(m, STATUS, 0xF)
    assert await rd_ok(m, STATUS) == 0x4
    await wr_ok(m, STATUS, 0x0, strb=0x2)
    assert await rd_ok(m, STATUS) == 0x4, "IRQ_EN changed without its strobe"
    await wr_ok(m, STATUS, 0x0)
    assert await rd_ok(m, STATUS) == 0
    # RD_ADDR read back; read-only registers ignore writes with OKAY
    await wr_ok(m, RD_ADDR, 0x3A5)
    assert await rd_ok(m, RD_ADDR) == 0x3A5
    for r in (RD_DATA, CYCLES, IRQ, ID):
        await wr_ok(m, r, 0xFFFF_FFFE)
    assert await rd_ok(m, ID) == ID_VALUE
    assert await rd_ok(m, CYCLES) == 0
    # Unmapped / misaligned / outside 0x2000_xxxx: SLVERR, read data 0
    for a in (0x20, 0x24, 0x100, 0xFFFC, 0x2, 0x1_0000, 0x0FFF_0000):
        assert await m.write(a, 0x1234) == SLVERR, f"write {a:#x} not SLVERR"
        assert await m.read(a) == (0, SLVERR), f"read {a:#x} not SLVERR / 0"
    # The decoder's nibble (addr[31:28]) is ignored
    assert await rd_ok(m, 0x2000_0000 | ID) == ID_VALUE
    # Action registers need all four strobes
    assert await m.write(LOAD, 0, strb=0x7) == SLVERR
    assert await m.write(RD_ADDR, 0, strb=0x3) == SLVERR
    # Illegal N on START: not a multiple of 4, below 4, above 64
    for n in (0, 3, 6, 65, 68, 127):
        assert await m.write(CTRL, (n << 8) | 1) == SLVERR, f"START with N={n} accepted"
        assert (await rd_ok(m, STATUS)) & 1 == 0, f"N={n} made the engine busy"
    assert await rd_ok(m, CTRL) == 40 << 8, "a rejected START changed N_LEN"
    done_check(mon)


@cocotb.test()
async def backpressure_all_channels(dut):
    """Interleaved writes and reads with heavy random stalls on AW, W, B, AR, R."""
    m, mon, rng = await setup(dut, 3, stall=0.7)
    model = {"n": 4, "rd": 0}

    async def writer():
        for _ in range(150):
            if rng.random() < 0.5:
                n = rng.randrange(4, 65)
                await wr_ok(m, CTRL, n << 8)
                model["n"] = n
            else:
                a = rng.randrange(1024)
                await wr_ok(m, RD_ADDR, a)
                model["rd"] = a

    async def reader():
        for _ in range(150):
            r = rng.choice([CTRL, RD_ADDR, ID])
            v = await rd_ok(m, r)
            if r == ID:
                assert v == ID_VALUE
            elif r == CTRL:
                assert 4 <= v >> 8 <= 64 and v & 0xFF == 0
            else:
                assert v < 1024

    w = cocotb.start_soon(writer())
    await reader()
    await w
    assert await rd_ok(m, CTRL) == model["n"] << 8
    assert await rd_ok(m, RD_ADDR) == model["rd"]

    # Pipelined traffic: requests run ahead of stalled responses, so the
    # slave must hold AWREADY / WREADY / ARREADY low.
    for _ in range(20):
        ops = [(CTRL, rng.randrange(4, 65) << 8) for _ in range(rng.randint(2, 6))]
        ops.append((0x40, 0))  # unmapped, in the middle of the stream's order
        ops += [(RD_ADDR, rng.randrange(1024))]
        resps = await m.write_many(ops)
        assert resps == [OKAY] * (len(ops) - 2) + [SLVERR, OKAY], resps
        regs = [rng.choice([CTRL, RD_ADDR, ID, 0x44]) for _ in range(rng.randint(2, 6))]
        got = await m.read_many(regs)
        want = {CTRL: (ops[-3][1], OKAY), RD_ADDR: (ops[-1][1], OKAY), ID: (ID_VALUE, OKAY),
                0x44: (0, SLVERR)}
        assert got == [want[r] for r in regs], (regs, got)
    done_check(mon)
    assert all(mon.stalls[c] > 0 for c in ("aw", "w", "b", "ar", "r")), mon.stalls
    dut._log.info(f"handshakes {mon.hs}, stalled cycles {mon.stalls}")


async def load_matrix(m, sel, mat):
    for row, vals in enumerate(mat):
        for col, v in enumerate(vals):
            await wr_ok(m, LOAD, (sel << 20) | (((row << 4) | col) << 8) | (v & 0xFF))


async def run_attention(dut, m, mon, rng, n, use_irq):
    q, k, v = ([[rng.randint(-128, 127) for _ in range(16)] for _ in range(n)] for _ in range(3))
    for sel, mat in enumerate((q, k, v)):
        await load_matrix(m, sel, mat)
    await wr_ok(m, STATUS, 0x4 if use_irq else 0x0)
    await wr_ok(m, CTRL, (n << 8) | 1)
    st = await rd_ok(m, STATUS)
    assert st & 1, "BUSY not set right after START"
    # While busy: LOAD and START are refused, RD_ADDR is allowed
    assert await m.write(LOAD, 0) == SLVERR, "LOAD accepted while busy"
    assert await m.write(CTRL, (n << 8) | 1) == SLVERR, "START accepted while busy"
    for _ in range(20000):
        if use_irq:
            await RisingEdge(dut.clk)
            if int(dut.irq.value):
                break
        elif (await rd_ok(m, STATUS)) & 2:
            break
    else:
        raise AssertionError(f"N={n}: no DONE")
    st = await rd_ok(m, STATUS)
    assert st & 0x3 == 0x2, f"STATUS {st:#x}: expected DONE and not BUSY"
    if use_irq:
        assert await rd_ok(m, IRQ) == 1
    cyc = await rd_ok(m, CYCLES)
    assert cyc == expected_cycles(n), f"N={n}: CYCLES {cyc}, expected {expected_cycles(n)}"
    exp = attn.attn_fixed(q, k, v, LUT)
    bad = 0
    for row in range(n):
        for col in range(16):
            await wr_ok(m, RD_ADDR, (row << 4) | col)
            got = await rd_ok(m, RD_DATA)
            want = exp[row][col] & 0xFF
            if got != want:
                bad += 1
                if bad <= 4:
                    dut._log.error(f"N={n} out[{row}][{col}] = {got:#04x}, model {want:#04x}")
    assert bad == 0, f"N={n}: {bad} of {16 * n} outputs differ from attn_fixed"
    # DONE is sticky until cleared through IRQ (write 1)
    assert (await rd_ok(m, STATUS)) & 2
    await wr_ok(m, IRQ, 1)
    assert (await rd_ok(m, STATUS)) & 2 == 0
    assert int(dut.irq.value) == 0
    dut._log.info(f"N={n}: 0 mismatches, {cyc} accelerator cycles")


@cocotb.test()
async def attention_runs(dut):
    """N = 4, 16, 64 against attn_fixed, random back-pressure throughout."""
    m, mon, rng = await setup(dut, 4, stall=0.3)
    for n, irq in ((4, False), (16, True), (64, False)):
        await run_attention(dut, m, mon, rng, n, irq)
    done_check(mon)


@cocotb.test()
async def back_to_back_reads(dut):
    """Several RD_ADDR writes before one RD_DATA read: the read waits for all
    of them and returns the last byte; ordering through both FIFOs holds."""
    m, mon, rng = await setup(dut, 5, stall=0.2)
    n = 8
    q, k, v = ([[rng.randint(-128, 127) for _ in range(16)] for _ in range(n)] for _ in range(3))
    for sel, mat in enumerate((q, k, v)):
        await load_matrix(m, sel, mat)
    await wr_ok(m, CTRL, (n << 8) | 1)
    while not (await rd_ok(m, STATUS)) & 2:
        pass
    exp = attn.attn_fixed(q, k, v, LUT)
    for _ in range(40):
        addrs = [rng.randrange(n * 16) for _ in range(rng.randint(1, 9))]
        for a in addrs:
            await wr_ok(m, RD_ADDR, a)
        got = await rd_ok(m, RD_DATA)
        a = addrs[-1]
        assert got == exp[a >> 4][a & 15] & 0xFF, f"RD_DATA after {addrs}"
    done_check(mon)
