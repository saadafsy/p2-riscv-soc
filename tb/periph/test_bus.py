"""obi_decoder in the data-side memory system: routing to RAM, the APB
peripherals and the default slave; back-to-back and mixed traffic."""

import random

import cocotb
from cocotb.triggers import ClockCycles

from tbutil import ObiMaster, assert_quiet, start, val

UART, GPIO, TIMER, SIM = 0x1000_0000, 0x1000_1000, 0x1000_2000, 0x1000_F000
CHK = ["chk_core", "chk_ifetch", "chk_ram", "chk_br", "chk_apb"]
IDLE = {"m_req": 0, "m_addr": 0, "m_we": 0, "m_be": 0, "m_wdata": 0,
        "i_req": 0, "i_addr": 0, "uart_rx": 1, "gpio_in": 0}


def rd(a):
    return (a, 0, 0xF, 0)


def wr(a, d, be=0xF):
    return (a, 1, be, d)


async def setup(dut):
    await start(dut, IDLE)
    return ObiMaster(dut, "m_")


@cocotb.test()
async def test_ram_back_to_back(dut):
    m = await setup(dut)
    n = 64
    await m.run([wr(4 * i, 0x100 + i) for i in range(n)])
    assert m.cycles == n + 1, f"RAM writes not back to back: {m.cycles}"
    got = await m.run([rd(4 * i) for i in range(n)])
    assert got == [0x100 + i for i in range(n)]
    assert m.cycles == n + 1
    # top of the 64 KB and aliasing above it
    await m.write(0x0000_FFFC, 0xCAFE_F00D)
    assert await m.read(0x0000_FFFC) == 0xCAFE_F00D
    assert await m.read(0x0001_FFFC) == 0xCAFE_F00D
    assert_quiet(dut, CHK)


@cocotb.test()
async def test_apb_targets(dut):
    m = await setup(dut)
    await m.write(UART + 0x8, 0x1234)
    assert await m.read(UART + 0x8) == 0x1234
    assert await m.read(UART + 0x4) == 0x2, "UART STATUS tx_empty"
    await m.write(GPIO + 0x0, 0x00A5)
    assert val(dut.gpio_out) == 0x00A5
    await m.write(GPIO + 0x8, 0x0F00)
    await m.write(GPIO + 0xC, 0x0005)
    assert await m.read(GPIO + 0x0) == 0x0FA0
    t0 = await m.read(TIMER + 0x0)
    t1 = await m.read(TIMER + 0x0)
    assert t1 - t0 == 5, (t0, t1)  # 4-cycle read plus the driver's idle cycle
    await m.write(SIM + 0x0, 7)
    assert val(dut.u_sim.exit_seen) == 1 and val(dut.u_sim.exit_code) == 7
    assert await m.read(SIM + 0x0) == 0
    assert await m.read(0x1000_5000) == 0, "unpopulated APB slot"
    assert_quiet(dut, CHK)


@cocotb.test()
async def test_subword_store_to_peripheral(dut):
    m = await setup(dut)
    await m.write(GPIO + 0x0, 0xFFFF)
    # sb to byte 1: only that lane changes (APB4 pstrb, spec 5)
    await m.write(GPIO + 0x1, 0x0000_3C00, be=0b0010)
    assert val(dut.gpio_out) == 0x3CFF
    assert await m.read(GPIO + 0x0) == 0x3CFF
    await m.write(GPIO + 0x8, 0x0000_0001, be=0b0001)  # sb to OUT_SET
    await m.write(GPIO + 0xC, 0xFFFF_0000, be=0b1100)  # sh to OUT_CLR above OUT: no-op
    assert val(dut.gpio_out) == 0x3CFF
    await m.write(UART + 0x9, 0x0000_0200, be=0b0010)  # sb to DIVISOR byte 1
    assert await m.read(UART + 0x8) == 0x0264  # 868 = 0x364
    await m.write(TIMER + 0xE, 0x1234_0000, be=0b1100)  # sh to MTIMECMP_HI upper half
    assert await m.read(TIMER + 0xC) == 0x1234_FFFF
    await m.write(SIM + 0x1, 0x0000_0700, be=0b0010)  # sb to EXIT byte 1
    assert val(dut.u_sim.exit_code) == 0x0700
    assert_quiet(dut, CHK)


@cocotb.test()
async def test_default_slave(dut):
    m = await setup(dut)
    await m.write(0x0000_0010, 0x1111_2222)
    for a in [0x2000_0000, 0x3000_0010, 0x8000_0000, 0xF000_0010]:
        await m.write(a, 0xDEAD_BEEF)
        assert await m.read(a) == 0
    assert await m.read(0x0000_0010) == 0x1111_2222, "default-slave write leaked into RAM"
    n = 16
    await m.run([rd(0x4000_0000 + 4 * i) for i in range(n)])
    assert m.cycles == n + 1, "default slave answers back to back"
    assert_quiet(dut, CHK)


@cocotb.test()
async def test_mixed_back_to_back(dut):
    """Target switches with no idle cycles: response routing by registered select."""
    m = await setup(dut)
    await m.run([wr(0x40, 0xAAAA_0001), wr(GPIO, 0x0042), wr(0x44, 0xAAAA_0002)])
    seq = [rd(0x40), rd(GPIO), rd(0x2000_0040), rd(0x44), rd(UART + 0x8), rd(0x40),
           rd(0x3000_0000), rd(GPIO), rd(0x44)]
    got = await m.run(seq)
    assert got == [0xAAAA_0001, 0x42, 0, 0xAAAA_0002, 868, 0xAAAA_0001, 0, 0x42,
                   0xAAAA_0002]
    assert_quiet(dut, CHK)


@cocotb.test()
async def test_random_traffic_with_ifetch(dut):
    rng = random.Random(21)
    m = await setup(dut)
    f = ObiMaster(dut, "i_", read_only=True, seed=9)
    ram = {}
    gpio = 0
    txns, exp = [], []
    for _ in range(800):
        r = rng.random()
        if r < 0.55:
            w = rng.randrange(64)
            if rng.random() < 0.5:
                d = rng.getrandbits(32)
                txns.append(wr(4 * w, d))
                exp.append(None)
                ram[w] = d
            elif w in ram:
                txns.append(rd(4 * w))
                exp.append(ram[w])
            else:
                ram[w] = w
                txns.append(wr(4 * w, w))
                exp.append(None)
        elif r < 0.8:
            if rng.random() < 0.5:
                gpio = rng.getrandbits(16)
                txns.append(wr(GPIO, gpio))
                exp.append(None)
            else:
                txns.append(rd(GPIO))
                exp.append(gpio)
        else:
            a = rng.choice([0x2000_0000, 0x5000_0000, 0xFFFF_FFFC])
            txns.append(wr(a, 1) if rng.random() < 0.5 else rd(a))
            exp.append(None if txns[-1][1] else 0)
    # instruction port reads words the data port also writes; only rate is checked here
    fetch = cocotb.start_soon(f.run([rd(4 * (i % 64)) for i in range(400)], idle_prob=0.2))
    assert await m.run(txns, idle_prob=0.15) == exp
    assert len(await fetch) == 400
    await ClockCycles(dut.clk, 2)
    assert_quiet(dut, CHK)
