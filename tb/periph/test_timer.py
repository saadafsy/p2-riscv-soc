"""timer_apb: mtime counting and writes, mtimecmp, byte-lane writes, irq_timer."""

import random

import cocotb
from cocotb.triggers import ClockCycles, FallingEdge

from tbutil import APB_IDLE, ApbMaster, assert_quiet, lane_mask, start, val

TLO, THI, CLO, CHI = 0x0, 0x4, 0x8, 0xC
CHK = ["chk_apb"]


async def setup(dut):
    await start(dut, APB_IDLE)
    return ApbMaster(dut)


def mtime(dut):
    return val(dut.dut.mtime)


@cocotb.test()
async def test_reset_values(dut):
    apb = await setup(dut)
    assert await apb.read(CLO) == 0xFFFF_FFFF and await apb.read(CHI) == 0xFFFF_FFFF
    assert await apb.read(THI) == 0
    assert val(dut.irq_timer) == 0
    assert await apb.read(0x10) == 0
    assert_quiet(dut, CHK)


@cocotb.test()
async def test_mtime_counts(dut):
    apb = await setup(dut)
    # each read is 3 cycles (SETUP, ACCESS, idle); data sampled in ACCESS
    a = await apb.read(TLO)
    b = await apb.read(TLO)
    assert b - a == 3, (a, b)
    m0 = mtime(dut)
    await ClockCycles(dut.clk, 100)
    await FallingEdge(dut.clk)
    assert mtime(dut) - m0 == 100


@cocotb.test()
async def test_mtime_write_and_carry(dut):
    apb = await setup(dut)
    await apb.write(THI, 0x0000_0007)
    await apb.write(TLO, 0xFFFF_FFF0)
    hi_before = await apb.read(THI)
    assert hi_before == 7
    await ClockCycles(dut.clk, 32)
    assert await apb.read(THI) == 8, "carry from LO into HI"
    assert mtime(dut) >> 32 == 8
    assert_quiet(dut, CHK)


@cocotb.test()
async def test_compare_exact(dut):
    apb = await setup(dut)
    await apb.write(TLO, 0)
    await apb.write(CLO, 200)
    await apb.write(CHI, 0)
    # mtime >= mtimecmp must first hold in exactly the cycle mtime reaches 200
    while True:
        await FallingEdge(dut.clk)
        m = mtime(dut)
        irq = val(dut.irq_timer)
        assert irq == int(m >= 200), (m, irq)
        if m >= 205:
            break
    # raising mtimecmp clears the irq; 64-bit compare uses the high word
    await apb.write(CHI, 1)
    assert val(dut.irq_timer) == 0
    await apb.write(THI, 1)
    await apb.write(TLO, 0)
    assert val(dut.irq_timer) == 0
    await ClockCycles(dut.clk, 220)
    assert val(dut.irq_timer) == 1
    await apb.write(CHI, 0xFFFF_FFFF)
    assert val(dut.irq_timer) == 0
    assert_quiet(dut, CHK)


@cocotb.test()
async def test_subword_writes(dut):
    """Every timer half takes byte-lane writes; other bytes keep their value."""
    apb = await setup(dut)
    rng = random.Random(3)
    cmp_model = {CLO: 0xFFFF_FFFF, CHI: 0xFFFF_FFFF}
    for _ in range(60):
        reg = rng.choice([CLO, CHI])
        v, s = rng.getrandbits(32), rng.getrandbits(4)
        await apb.write(reg, v, strb=s)
        m = lane_mask(s)
        cmp_model[reg] = cmp_model[reg] & ~m | v & m
        assert val(dut.dut.mtimecmp) == cmp_model[CHI] << 32 | cmp_model[CLO]
    for reg in (CLO, CHI):
        assert await apb.read(reg) == cmp_model[reg]
    await apb.write(CHI, 0xFFFF_FFFF)  # keep irq_timer quiet for the mtime part
    # MTIME_HI: low word small, so no carry reaches HI during the test
    await apb.write(TLO, 0)
    await apb.write(THI, 0x1122_3344)
    await apb.write(THI, 0x00AA_0000, strb=0b0100)
    assert await apb.read(THI) == 0x11AA_3344
    await apb.write(THI + 1, 0x0000_BB00, strb=0b0010)
    await apb.write(THI, 0xCC00_00DD, strb=0b1001)
    assert await apb.read(THI) == 0xCCAA_BBDD
    # MTIME_LO: a byte write replaces that byte; the rest keeps counting from
    # the value it held (the write cycle skips the increment)
    await apb.write(TLO, 0x5566_7700)
    await apb.write(TLO + 3, 0xEE00_0000, strb=0b1000)
    lo = await apb.read(TLO)
    assert lo >> 8 == 0xEE66_77, hex(lo)
    assert await apb.read(THI) == 0xCCAA_BBDD
    a = await apb.read(TLO)
    await apb.write(TLO, 0, strb=0)  # no lanes: no write, counting goes on
    b = await apb.read(TLO)
    assert b - a == 6, (a, b)
    assert_quiet(dut, CHK)
