"""gpio_apb: OUT read/write, SET/CLR, byte-lane writes, IN synchronizer latency."""

import random

import cocotb
from cocotb.triggers import ClockCycles, FallingEdge

from tbutil import APB_IDLE, ApbMaster, assert_quiet, lane_mask, start, val

OUT, IN, SET, CLR = 0x0, 0x4, 0x8, 0xC
CHK = ["chk_apb"]


async def setup(dut):
    await start(dut, APB_IDLE | {"gpio_in": 0})
    return ApbMaster(dut)


@cocotb.test()
async def test_out_rw(dut):
    apb = await setup(dut)
    assert await apb.read(OUT) == 0 and val(dut.gpio_out) == 0
    await apb.write(OUT, 0xDEAD_BEEF)
    assert val(dut.gpio_out) == 0xBEEF, "16 LED bits"
    assert await apb.read(OUT) == 0xBEEF
    assert await apb.read(SET) == 0xBEEF and await apb.read(CLR) == 0xBEEF
    assert await apb.read(0x10) == 0
    await apb.write(OUT + 2, 0x1234)  # byte address inside OUT hits OUT
    assert await apb.read(OUT + 3) == 0x1234
    assert_quiet(dut, CHK)


@cocotb.test()
async def test_set_clr(dut):
    apb = await setup(dut)
    rng = random.Random(5)
    model = 0
    for _ in range(40):
        op = rng.choice([OUT, SET, CLR])
        v = rng.getrandbits(32)
        await apb.write(op, v)
        if op == OUT:
            model = v & 0xFFFF
        elif op == SET:
            model |= v & 0xFFFF
        else:
            model &= ~v & 0xFFFF
        assert val(dut.gpio_out) == model
    assert await apb.read(OUT) == model
    assert_quiet(dut, CHK)


@cocotb.test()
async def test_in_sync(dut):
    apb = await setup(dut)
    await FallingEdge(dut.clk)
    dut.gpio_in.value = 0x1F_A5C3
    # two flops: visible on IN after exactly two rising edges
    await FallingEdge(dut.clk)
    assert val(dut.dut.in_s) == 0
    await FallingEdge(dut.clk)
    assert val(dut.dut.in_s) == 0x1F_A5C3
    assert await apb.read(IN) == 0x1F_A5C3
    dut.gpio_in.value = 0x0A_0001
    await ClockCycles(dut.clk, 3)
    assert await apb.read(IN) == 0x0A_0001
    await apb.write(IN, 0xFFFF_FFFF)  # read-only: ignored
    assert val(dut.gpio_out) == 0 and await apb.read(IN) == 0x0A_0001
    assert_quiet(dut, CHK)


@cocotb.test()
async def test_subword_writes(dut):
    """OUT, OUT_SET, OUT_CLR change only the pstrb-enabled lanes (spec 5, 8)."""
    apb = await setup(dut)
    await apb.write(OUT, 0xFFFF)
    await apb.write(OUT + 1, 0x0000_CD00, strb=0b0010)  # sb to byte 1
    assert val(dut.gpio_out) == 0xCDFF
    await apb.write(OUT, 0x0000_0055, strb=0b0001)
    assert await apb.read(OUT) == 0xCD55
    await apb.write(OUT + 2, 0xFFFF_0000, strb=0b1100)  # lanes above OUT's 16 bits
    assert val(dut.gpio_out) == 0xCD55
    await apb.write(SET, 0xFFFF_FFFF, strb=0b0010)
    assert val(dut.gpio_out) == 0xFF55
    await apb.write(CLR, 0xFFFF_FFFF, strb=0b0001)
    assert val(dut.gpio_out) == 0xFF00
    await apb.write(OUT, 0x1234, strb=0)  # no lanes: no change
    await apb.write(SET, 0xFFFF, strb=0)
    await apb.write(CLR, 0xFFFF, strb=0)
    assert val(dut.gpio_out) == 0xFF00
    rng = random.Random(11)
    model = 0xFF00
    for _ in range(200):
        op = rng.choice([OUT, SET, CLR])
        v, s = rng.getrandbits(32), rng.getrandbits(4)
        await apb.write(op + rng.randrange(4), v, strb=s)
        m = lane_mask(s) & 0xFFFF
        if op == OUT:
            model = model & ~m | v & m
        elif op == SET:
            model |= v & m
        else:
            model &= ~(v & m) & 0xFFFF
        assert val(dut.gpio_out) == model, (op, hex(v), s)
    assert_quiet(dut, CHK)
