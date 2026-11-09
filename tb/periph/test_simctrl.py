"""simctrl_apb (FINISH_ON_EXIT=0): EXIT and PUTC, reads return 0."""

import cocotb

from tbutil import APB_IDLE, ApbMaster, assert_quiet, start, val

EXIT, PUTC = 0x0, 0x4
CHK = ["chk_apb"]


@cocotb.test()
async def test_putc_exit(dut):
    await start(dut, APB_IDLE)
    apb = ApbMaster(dut)
    for ch in b"simctrl ok\n":
        await apb.write(PUTC, ch)
    assert val(dut.dut.exit_seen) == 0, "PUTC must not count as EXIT"
    assert await apb.read(EXIT) == 0 and await apb.read(PUTC) == 0
    await apb.write(EXIT, 42)
    assert val(dut.dut.exit_seen) == 1 and val(dut.dut.exit_code) == 42
    assert await apb.read(EXIT) == 0
    assert_quiet(dut, CHK)


@cocotb.test()
async def test_subword_writes(dut):
    """PUTC prints only with pstrb[0]; EXIT takes the enabled lanes, pstrb 0 is no write."""
    await start(dut, APB_IDLE)
    apb = ApbMaster(dut)
    await apb.write(PUTC, ord("a"), strb=0b0001)
    await apb.write(PUTC, ord("b") << 8, strb=0b0010)
    await apb.write(PUTC, 0x6363_6363, strb=0b1110)
    assert val(dut.dut.putc_count) == 1
    await apb.write(PUTC + 1, 0x0000_6400, strb=0b0011)  # lane 0 still enabled
    assert val(dut.dut.putc_count) == 2
    await apb.write(EXIT, 0xFFFF_FFFF, strb=0)
    assert val(dut.dut.exit_seen) == 0, "pstrb 0 must not count as EXIT"
    await apb.write(EXIT + 3, 0xAB00_00FF, strb=0b1000)
    assert val(dut.dut.exit_seen) == 1 and val(dut.dut.exit_code) == 0xAB00_0000
    await apb.write(EXIT, 0x1234_5602, strb=0b0001)
    assert val(dut.dut.exit_code) == 0x02
    assert_quiet(dut, CHK)
