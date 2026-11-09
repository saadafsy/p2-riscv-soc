"""jtag_debug tests: TAP FSM against the 1149.1 state model (all 16 states,
all 32 transitions), TMS and TRST reset, IR capture, IDCODE, BYPASS, and the
debug transport writing and reading a Python OBI memory with random gnt /
rvalid latency at tck much slower, slightly slower and faster than clk
(clk = 10 ns). The OBI checker in tb_jtag watches the master port.
"""

import random
from collections import deque

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge

from jtag_drv import (CAPDR, DR_LEN, EX1DR, IDCODE, IR_BYPASS, IR_DBG, IR_IDCODE, NAME, NEXT,
                      OP_NOP, OP_READ, OP_STATUS, OP_WRITE, RTI, SHDR, ST_BUSY, ST_ERR, ST_OK,
                      TLR, UPDR, Jtag, ObiMemory, dr_fields, val)

CLK_PS = 10000


async def por(dut, period_ps=CLK_PS * 3, **mem_kw):
    """Common power-on reset of both domains (rtl/debug/README.md, Resets)."""
    dut.trst.value = 1
    dut.rst.value = 1
    Clock(dut.clk, CLK_PS, unit="ps").start()
    mem = ObiMemory(dut, **mem_kw)
    cocotb.start_soon(mem.run())
    j = Jtag(dut, period_ps)
    for _ in range(3):
        await j.clock(1)
    await ClockCycles(dut.clk, 3)
    await FallingEdge(dut.clk)
    dut.rst.value = 0
    dut.trst.value = 0
    j.state = TLR
    assert val(dut.tap_state) == TLR
    await j.clock(0)
    return j, mem


def path_to(target):
    """Shortest TMS sequence from TLR to target (BFS over the model)."""
    q = deque([(TLR, [])])
    seen = {TLR}
    while q:
        s, p = q.popleft()
        if s == target:
            return p
        for tms in (0, 1):
            n = NEXT[s][tms]
            if n not in seen:
                seen.add(n)
                q.append((n, p + [tms]))
    raise AssertionError


@cocotb.test()
async def tap_fsm_walk(dut):
    """Random TMS for 3000 cycles; state checked every cycle; every state and
    every (state, TMS) transition must be hit."""
    j, _ = await por(dut)
    rng = random.Random(11)
    for _ in range(3000):
        # Bias toward 0 sometimes so the Pause and Shift loops are exercised.
        await j.clock(int(rng.random() < rng.choice((0.3, 0.5, 0.7))))
        assert val(dut.tap_state) == j.state, f"rtl {val(dut.tap_state):x} model {NAME[j.state]}"
    states = {s for s, _ in j.trace}
    edges = set(j.trace)
    assert len(states) == 16, sorted(NAME[s] for s in states)
    assert len(edges) == 32, f"{len(edges)} transitions"


@cocotb.test()
async def tms_reset_from_every_state(dut):
    """From each of the 16 states, five TMS=1 reach TLR and reload IDCODE into
    the IR; four are not always enough (from Shift-DR they are not)."""
    j, _ = await por(dut)
    for target in NEXT:
        await j.reset()
        await j.ir(IR_BYPASS)
        assert val(dut.tap_ir) == IR_BYPASS
        for _ in range(5):
            await j.clock(1)
        j.state = TLR
        for t in path_to(target):
            await j.clock(t)
        assert val(dut.tap_state) == target
        for _ in range(5):
            await j.clock(1)
        assert val(dut.tap_state) == TLR, f"not reset from {NAME[target]}"
        assert val(dut.tap_ir) == IR_IDCODE
        j.state = TLR
        await j.clock(0)
    for t in path_to(SHDR):
        await j.clock(t)
    for _ in range(4):
        await j.clock(1)
    assert val(dut.tap_state) != TLR


@cocotb.test()
async def trst_resets(dut):
    """TRST from Shift-DR with a non-default IR returns to TLR / IDCODE."""
    j, _ = await por(dut)
    await j.ir(IR_BYPASS)
    for t in (1, 0, 0):
        await j.clock(t)
    assert val(dut.tap_state) == SHDR
    dut.trst.value = 1
    j.state = None
    await j.clock(0)
    dut.trst.value = 0
    assert val(dut.tap_state) == TLR and val(dut.tap_ir) == IR_IDCODE


@cocotb.test()
async def idcode_and_ir_capture(dut):
    """IDCODE is selected after reset; the IR shifts out 00001 on capture;
    tdo_oe is high only while shifting."""
    j, _ = await por(dut)
    assert await j.dr(0, 32) == IDCODE
    assert await j.ir(IR_IDCODE) == 0b00001
    assert await j.dr(0, 32) == IDCODE
    # A longer scan shows the register then the bits shifted in behind it.
    pat = 0x9_1234_5678
    out = await j.dr(pat, 68)
    assert out & 0xFFFFFFFF == IDCODE
    assert out >> 32 == pat
    assert val(dut.tdo_oe) == 0
    for t in (1, 0, 0, 0):
        await j.clock(t)
    assert val(dut.tdo_oe) == 1
    for t in (1, 1, 0):
        await j.clock(t)
    assert j.state == RTI and val(dut.tdo_oe) == 0


@cocotb.test()
async def bypass(dut):
    """BYPASS (and unimplemented codes) delay TDI by one bit, capturing 0."""
    j, _ = await por(dut)
    rng = random.Random(3)
    for code in (IR_BYPASS, 0x00, 0x0A, 0x02):
        await j.ir(code)
        pat = rng.getrandbits(40) | 1 << 39
        out = await j.dr(pat, 41)
        assert out == pat << 1, f"IR {code:#x}: {out:#x}"


async def rw_traffic(dut, period_ps, seed, n=40):
    j, mem = await por(dut, period_ps, seed=seed, p_gnt=0.5, max_lat=6)
    rng = random.Random(seed)
    await j.ir(IR_DBG)
    shadow, writes = {}, []
    addrs = [rng.randrange(0, 1 << 30) << 2 for _ in range(n)]
    addrs[:3] = [0x0, 0x0000_FFFC, 0x1000_0000]
    for a in addrs:
        d = rng.getrandbits(32)
        st, echo = await j.dbg_write(a, d, idle=rng.randrange(0, 20))
        assert (st, echo) == (ST_OK, a)
        shadow[a] = d
        writes.append((1, a, d, 0xF))
    order = addrs[:] + [rng.randrange(0, 1 << 30) << 2 for _ in range(10)]
    rng.shuffle(order)
    for a in order:
        st, data, echo = await j.dbg_read(a, idle=rng.randrange(0, 20))
        assert (st, echo) == (ST_OK, a)
        assert data == shadow.get(a, mem.word(a)), f"{a:#x}: {data:#x}"
    # Exactly one bus transfer per op, in order: none lost, none duplicated.
    assert mem.log[:n] == writes
    assert [(w, a, b) for w, a, _, b in mem.log[n:]] == [(0, a, 0xF) for a in order]


@cocotb.test()
async def dbg_rw_tck_much_slower(dut):
    """tck period 237 ns vs clk 10 ns."""
    await rw_traffic(dut, 237_000, 21)


@cocotb.test()
async def dbg_rw_tck_slightly_slower(dut):
    """tck period 11.3 ns vs clk 10 ns: the edges drift through every phase."""
    await rw_traffic(dut, 11_300, 22)


@cocotb.test()
async def dbg_rw_tck_faster(dut):
    """tck period 7.1 ns: the handshake does not depend on the clock ratio."""
    await rw_traffic(dut, 7_100, 23)


@cocotb.test()
async def dbg_write_data_reaches_bus(dut):
    """Write data and byte enables on the bus are exactly what was scanned."""
    j, mem = await por(dut, 30_000, seed=5)
    await j.ir(IR_DBG)
    for a, d in ((0x100, 0xDEADBEEF), (0x104, 0x0), (0x108, 0xFFFFFFFF)):
        assert await j.dbg_write(a, d) == (ST_OK, a)
        assert mem.log[-1] == (1, a, d, 0xF)


@cocotb.test()
async def dbg_busy_error_status(dut):
    """Slow slave (300..400 clk): a scan straight after READ shows BUSY with the
    data masked; a WRITE while busy is dropped and sets the sticky error; NOP
    keeps it; STATUS clears it. Misaligned addresses and an Update-DR
    without a shift do not reach the bus."""
    j, mem = await por(dut, 7_100, seed=6, p_gnt=1.0, min_lat=300, max_lat=400)
    await j.ir(IR_DBG)
    await j.dbg_scan(OP_READ, 0x40, 0, idle=0)
    st, data, addr = await j.dbg_scan(OP_NOP, idle=0)
    assert (st, data, addr) == (ST_BUSY, 0, 0x40)
    st, _, _ = await j.dbg_scan(OP_WRITE, 0x80, 0x1111, idle=0)
    assert st == ST_BUSY
    (st, data, addr), nbusy = await j.dbg_poll(idle=2)
    assert nbusy > 0
    assert (st, data, addr) == (ST_ERR, mem.word(0x40), 0x40)
    assert [(w, a) for w, a, _, _ in mem.log] == [(0, 0x40)]
    (st, _, _), _ = await j.dbg_poll()
    assert st == ST_ERR, "error must be sticky across NOP"
    await j.dbg_scan(OP_STATUS)
    st, data, _ = await j.dbg_scan(OP_NOP)
    assert (st, data) == (ST_OK, mem.word(0x40))
    # Misaligned: dropped, error, last address unchanged.
    await j.dbg_scan(OP_READ, 0x42)
    (st, _, addr), _ = await j.dbg_poll()
    assert (st, addr) == (ST_ERR, 0x40) and len(mem.log) == 1
    await j.dbg_scan(OP_STATUS)
    # Capture -> Exit1 -> Update with no shift: the captured word is not an op.
    await j.dbg_scan(OP_NOP)
    for t in (1, 0, 1, 1, 0):
        await j.clock(t)
    assert j.trace[-3][0] == CAPDR and j.trace[-2][0] == EX1DR and j.trace[-1][0] == UPDR
    await j.idle(10)
    await ClockCycles(dut.clk, 20)
    assert len(mem.log) == 1
    # A normal access still works afterwards.
    assert await j.dbg_write(0x44, 0xABCD) == (ST_OK, 0x44)
    assert mem.log[-1] == (1, 0x44, 0xABCD, 0xF)


@cocotb.test()
async def dbg_scan_length(dut):
    """The debug DR is 66 bits: the first bits of a longer scan come out
    after the 66 captured ones."""
    j, _ = await por(dut)
    await j.ir(IR_DBG)
    marker = 0xA5
    out = await j.dr(marker, DR_LEN + 8)
    assert out >> DR_LEN == marker
    assert dr_fields(out) == (ST_OK, 0, 0)
