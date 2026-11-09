"""obi2apb: slot decode, SETUP/ACCESS sequencing, wait states, lane masking,
pstrb/pprot, unmapped slots, back-to-back requests."""

import random

import cocotb
from cocotb.triggers import FallingEdge, ReadOnly

from tbutil import ApbSlaveModel, ObiMaster, assert_quiet, lane_mask, start, val

BASE = 0x1000_0000
MAPPED = [0, 1, 2, 15]
CHK = ["chk_obi", "chk_apb"]
IDLE = {"req": 0, "addr": 0, "we": 0, "be": 0, "wdata": 0, "prdata": 0, "pready": 0xFFFF}


async def setup(dut, waits=None):
    await start(dut, IDLE)
    slv = ApbSlaveModel(dut, waits)
    cocotb.start_soon(slv.run())
    return ObiMaster(dut), slv


def addr_of(slot, off):
    return BASE | (slot << 12) | off


@cocotb.test()
async def test_slot_decode_rw(dut):
    m, slv = await setup(dut)
    for slot in MAPPED:
        await m.write(addr_of(slot, 0x10 + slot * 4), 0x1000 + slot)
    for slot in MAPPED:
        assert await m.read(addr_of(slot, 0x10 + slot * 4)) == 0x1000 + slot
    assert [(s, a, w) for s, a, w, _ in slv.log[:4]] == \
        [(s, 0x10 + s * 4, 1) for s in MAPPED]
    # addr[27:16] alias onto the same slot
    assert await m.read(0x1ABC_1014) == 0x1001
    assert_quiet(dut, CHK)


@cocotb.test()
async def test_unmapped_slot(dut):
    m, slv = await setup(dut)
    seen_psel = []

    async def mon():
        while True:
            await FallingEdge(dut.clk)
            seen_psel.append(val(dut.psel))

    t = cocotb.start_soon(mon())
    assert await m.read(addr_of(5, 0x0)) == 0
    await m.write(addr_of(9, 0x4), 0xFFFF_FFFF)
    assert await m.read(addr_of(14, 0x8)) == 0
    t.cancel()
    assert not any(seen_psel), "unmapped slot asserted psel"
    assert slv.log == []
    assert_quiet(dut, CHK)


@cocotb.test()
async def test_wait_states(dut):
    """pready held low for N cycles; check the latency and that the bridge
    holds SETUP/ACCESS signals (the APB checker enforces stability)."""
    m, slv = await setup(dut)
    for n in [0, 1, 3, 7, 12]:
        slv.waits = {1: n, 2: n}
        slv.access_cycles.clear()
        assert await m.read(addr_of(1, 0x8)) == (0xA5000000 | (1 << 16) | 0x8)
        # handshake, SETUP, N+1 ACCESS cycles, rvalid
        assert m.cycles == n + 4, (n, m.cycles)
        await m.write(addr_of(2, 0xC), 0x1234_5678)
        assert slv.log[-1] == (2, 0xC, 1, 0x1234_5678)
        assert slv.access_cycles == [n + 1, n + 1]
        assert_quiet(dut, CHK)


@cocotb.test()
async def test_byte_lane_masking(dut):
    m, slv = await setup(dut)
    for be, exp in [(0b0001, 0x0000_00DD), (0b0010, 0x0000_CC00), (0b1100, 0xAABB_0000),
                    (0b1111, 0xAABB_CCDD)]:
        await m.write(addr_of(0, 0x0), 0xAABB_CCDD, be=be)
        assert slv.log[-1][3] == exp, (be, hex(slv.log[-1][3]))
        assert slv.strb_log[-1] == (be, 0), (be, slv.strb_log[-1])
    assert_quiet(dut, CHK)


@cocotb.test()
async def test_pstrb_pprot(dut):
    """Every SETUP/ACCESS cycle: pstrb = be on writes, 0 on reads; pprot = 0."""
    m, _ = await setup(dut, waits={1: 2})
    seen = []

    async def mon():
        while True:
            await FallingEdge(dut.clk)
            await ReadOnly()
            if val(dut.psel):
                seen.append((val(dut.pwrite), val(dut.pstrb), val(dut.pprot)))

    t = cocotb.start_soon(mon())
    got = await m.run([(addr_of(1, 0x0), 1, 0b0110, 0x1122_3344), (addr_of(1, 0x0), 0, 0xF, 0),
                       (addr_of(1, 0x4), 0, 0b0001, 0),
                       (addr_of(1, 0x4), 1, 0b1000, 0xFF00_0000)])
    t.cancel()
    # 1 SETUP + 3 ACCESS cycles per transfer
    assert seen == [(1, 0b0110, 0)] * 4 + [(0, 0, 0)] * 8 + [(1, 0b1000, 0)] * 4, seen
    assert got[1] == 0xA522_3300, hex(got[1])  # slave model merged only lanes 1-2
    assert_quiet(dut, CHK)


@cocotb.test()
async def test_setup_access_sequence(dut):
    """Cycle-by-cycle: psel one-hot and penable only in the cycle after SETUP."""
    m, _ = await setup(dut, waits={15: 2})
    trace = []

    async def mon():
        while True:
            await FallingEdge(dut.clk)
            await ReadOnly()
            trace.append((val(dut.psel), val(dut.penable), val(dut.rvalid)))

    t = cocotb.start_soon(mon())
    await m.read(addr_of(15, 0x4))
    t.cancel()
    seq = [x for x in trace if x != (0, 0, 0)]
    assert seq == [(1 << 15, 0, 0), (1 << 15, 1, 0), (1 << 15, 1, 0), (1 << 15, 1, 0),
                   (0, 0, 1)], seq


@cocotb.test()
async def test_back_to_back_random(dut):
    rng = random.Random(7)
    m, slv = await setup(dut, waits={0: 0, 1: 2, 2: 1, 15: 4})
    model = {}
    txns, exp = [], []
    for _ in range(300):
        slot = rng.choice(MAPPED + [3, 8])
        off = rng.choice([0x0, 0x4, 0x8, 0xC])
        if rng.random() < 0.5:
            data = rng.getrandbits(32)
            be = rng.choice([0xF, 0x1, 0x2, 0x4, 0x8, 0x3, 0xC])
            txns.append((addr_of(slot, off), 1, be, data))
            exp.append(None)
            if slot in MAPPED:
                old = model.get((slot, off), 0xA5000000 | (slot << 16) | off)
                mk = lane_mask(be)
                model[(slot, off)] = old & ~mk | data & mk
        else:
            txns.append((addr_of(slot, off), 0, 0xF, 0))
            if slot in MAPPED:
                exp.append(model.get((slot, off), 0xA5000000 | (slot << 16) | off))
            else:
                exp.append(0)
    assert await m.run(txns, idle_prob=0.1) == exp
    assert_quiet(dut, CHK)
