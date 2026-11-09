"""uart_apb: registers, byte-lane writes, TX framing, RX loopback, FIFOs, overrun, irq."""

import cocotb
from cocotb.triggers import ClockCycles, FallingEdge

from tbutil import APB_IDLE, ApbMaster, assert_quiet, start, val

DATA, STATUS, DIV, IRQ_EN = 0x0, 0x4, 0x8, 0xC
TX_FULL, TX_EMPTY, RX_VALID, RX_OVR = 1, 2, 4, 8
CHK = ["chk_apb"]


async def setup(dut, div=None):
    await start(dut, APB_IDLE | {"rx": 1})
    apb = ApbMaster(dut)
    if div is not None:
        await apb.write(DIV, div)
    return apb


async def capture_tx(dut, nbytes, div, timeout=200000):
    """Decode nbytes frames from tx, checking every sample of every bit so
    each bit lasts exactly div cycles."""
    out = []
    waited = 0
    while len(out) < nbytes:
        await FallingEdge(dut.clk)
        if val(dut.tx):
            waited += 1
            assert waited < timeout, "no start bit on tx"
            continue
        waited = 0
        bits = []
        for b in range(10):
            samples = []
            for i in range(div):
                if b or i:
                    await FallingEdge(dut.clk)
                samples.append(val(dut.tx))
            assert len(set(samples)) == 1, f"bit {b} not stable for {div} cycles: {samples}"
            bits.append(samples[0])
        assert bits[0] == 0 and bits[9] == 1, f"bad framing {bits}"
        out.append(sum(bit << i for i, bit in enumerate(bits[1:9])))
    return out


async def send_rx(dut, data, div, stop_ok=True, bit_cycles=None):
    """Drive bit-accurate 8N1 frames back to back on rx (one stop bit)."""
    bc = bit_cycles if bit_cycles is not None else div
    for byte in data:
        bits = [0] + [(byte >> i) & 1 for i in range(8)] + [1 if stop_ok else 0]
        for bit in bits:
            dut.rx.value = bit
            for _ in range(bc):
                await FallingEdge(dut.clk)
    dut.rx.value = 1


@cocotb.test()
async def test_reset_and_registers(dut):
    apb = await setup(dut)
    assert await apb.read(DIV) == 868
    assert await apb.read(STATUS) == TX_EMPTY
    assert await apb.read(IRQ_EN) == 0
    assert await apb.read(DATA) == 0, "empty RX reads 0"
    await apb.write(DIV, 0xFFFF_1234)
    assert await apb.read(DIV) == 0x1234, "DIVISOR is 16 bits"
    await apb.write(IRQ_EN, 0xFFFF_FFFF)
    assert await apb.read(IRQ_EN) == 1
    assert await apb.read(0x10) == 0, "unmapped offset reads 0"
    assert val(dut.tx) == 1 and val(dut.irq) == 0
    assert_quiet(dut, CHK)


@cocotb.test()
async def test_tx_framing(dut):
    div = 6
    apb = await setup(dut, div)
    payload = [0x55, 0xA3, 0x00, 0xFF, 0x81]
    cap = cocotb.start_soon(capture_tx(dut, len(payload), div))
    for b in payload:
        await apb.write(DATA, 0x100 | b)  # upper bits ignored
    assert await cap == payload
    await ClockCycles(dut.clk, 3)
    assert await apb.read(STATUS) == TX_EMPTY
    assert_quiet(dut, CHK)


@cocotb.test()
async def test_tx_fifo_full(dut):
    div = 16  # a frame outlasts 17 APB writes, so the FIFO really fills
    apb = await setup(dut, div)
    cap = cocotb.start_soon(capture_tx(dut, 17, div))
    payload = list(range(0x30, 0x30 + 18))
    for b in payload[:17]:
        await apb.write(DATA, b)
    # one byte in the shifter, sixteen queued
    st = await apb.read(STATUS)
    assert st & TX_FULL and not st & TX_EMPTY, f"status {st:#x}"
    await apb.write(DATA, payload[17])  # dropped
    assert await cap == payload[:17]
    await ClockCycles(dut.clk, div * 12)
    assert await apb.read(STATUS) == TX_EMPTY, "dropped byte must not be sent"
    assert_quiet(dut, CHK)


@cocotb.test()
async def test_rx_back_to_back(dut):
    div = 8
    apb = await setup(dut, div)
    data = [0x5A, 0x00, 0xFF, 0x13, 0xC6]
    await send_rx(dut, data, div)
    await ClockCycles(dut.clk, 4)
    assert await apb.read(STATUS) & RX_VALID
    got = [await apb.read(DATA) for _ in data]
    assert got == [0x100 | b for b in data], [hex(g) for g in got]
    assert await apb.read(DATA) == 0
    assert not (await apb.read(STATUS)) & RX_VALID
    assert_quiet(dut, CHK)


@cocotb.test()
async def test_rx_tx_loopback(dut):
    """tx wired back to rx through the testbench."""
    div = 5
    apb = await setup(dut, div)

    async def wire():
        while True:
            await FallingEdge(dut.clk)
            dut.rx.value = val(dut.tx)

    w = cocotb.start_soon(wire())
    data = [0x11, 0xEE, 0x7F, 0x80]
    for b in data:
        await apb.write(DATA, b)
    await ClockCycles(dut.clk, div * 11 * len(data) + 20)
    w.cancel()
    got = [await apb.read(DATA) & 0x1FF for _ in data]
    assert got == [0x100 | b for b in data]
    assert_quiet(dut, CHK)


@cocotb.test()
async def test_rx_baud_tolerance_and_glitch(dut):
    div = 32
    apb = await setup(dut, div)
    # 3% slow sender
    await send_rx(dut, [0xA7], div, bit_cycles=33)
    # a glitch shorter than half a bit is not a start bit
    dut.rx.value = 0
    await ClockCycles(dut.clk, div // 2 - 3)
    dut.rx.value = 1
    await ClockCycles(dut.clk, 3 * div)
    assert await apb.read(DATA) == 0x1A7
    assert await apb.read(DATA) == 0, "glitch produced a byte"
    # bad stop bit discards the frame
    await send_rx(dut, [0x42], div, stop_ok=False)
    await ClockCycles(dut.clk, 2 * div)
    assert await apb.read(DATA) == 0, "frame with bad stop bit accepted"
    assert_quiet(dut, CHK)


@cocotb.test()
async def test_rx_overrun(dut):
    div = 4
    apb = await setup(dut, div)
    data = list(range(0xA0, 0xA0 + 17))
    await send_rx(dut, data, div)
    await ClockCycles(dut.clk, 4)
    st = await apb.read(STATUS)
    assert st & RX_OVR and st & RX_VALID, f"status {st:#x}"
    await apb.write(STATUS, RX_OVR)
    assert not (await apb.read(STATUS)) & RX_OVR, "overrun is W1C"
    got = [await apb.read(DATA) for _ in range(16)]
    assert got == [0x100 | b for b in data[:16]], "first 16 kept, 17th dropped"
    assert await apb.read(DATA) == 0
    assert_quiet(dut, CHK)


@cocotb.test()
async def test_irq(dut):
    div = 4
    apb = await setup(dut, div)
    await send_rx(dut, [0x31, 0x32], div)
    await ClockCycles(dut.clk, 4)
    assert val(dut.irq) == 0, "irq gated by IRQ_EN"
    await apb.write(IRQ_EN, 1)
    assert val(dut.irq) == 1
    await apb.read(DATA)
    assert val(dut.irq) == 1, "one byte still queued"
    await apb.read(DATA)
    assert val(dut.irq) == 0, "irq follows rx_valid"
    await send_rx(dut, [0x33], div)
    await ClockCycles(dut.clk, 4)
    assert val(dut.irq) == 1
    await apb.write(IRQ_EN, 0)
    assert val(dut.irq) == 0
    assert_quiet(dut, CHK)


@cocotb.test()
async def test_subword_writes(dut):
    """DIVISOR and IRQ_EN take byte lanes; STATUS W1C and DATA push need pstrb[0]."""
    apb = await setup(dut)
    await apb.write(DIV, 0x0000_1234)
    await apb.write(DIV + 1, 0x0000_AB00, strb=0b0010)
    assert await apb.read(DIV) == 0xAB34
    await apb.write(DIV, 0x0000_0056, strb=0b0001)
    assert await apb.read(DIV) == 0xAB56
    await apb.write(DIV + 2, 0xFFFF_0000, strb=0b1100)
    assert await apb.read(DIV) == 0xAB56, "lanes above DIVISOR's 16 bits"
    await apb.write(IRQ_EN, 0xFFFF_FFFE, strb=0b1110)
    assert await apb.read(IRQ_EN) == 0
    await apb.write(IRQ_EN, 0x0000_0001, strb=0b0001)
    assert await apb.read(IRQ_EN) == 1
    await apb.write(IRQ_EN, 0x0000_0000, strb=0b1110)
    assert await apb.read(IRQ_EN) == 1, "bit 0 lives in lane 0"
    # DATA: no push without pstrb[0]; with it, only the low byte is sent
    div = 4
    await apb.write(DIV, div)
    await apb.write(DATA, 0x5A5A_5A5A, strb=0b1110)
    await ClockCycles(dut.clk, 2)
    assert await apb.read(STATUS) == TX_EMPTY and val(dut.tx) == 1, "pushed without pstrb[0]"
    cap = cocotb.start_soon(capture_tx(dut, 1, div))
    await apb.write(DATA + 1, 0x0000_FF3C, strb=0b0011)
    assert await cap == [0x3C]
    # STATUS: overrun clears only on a write with pstrb[0] and bit 3 set
    await send_rx(dut, list(range(0x40, 0x40 + 17)), div)
    await ClockCycles(dut.clk, 4)
    assert await apb.read(STATUS) & RX_OVR
    await apb.write(STATUS, 0xFFFF_FFFF, strb=0b1110)
    assert await apb.read(STATUS) & RX_OVR, "cleared without pstrb[0]"
    await apb.write(STATUS + 1, 0xFFFF_FF00 | RX_OVR, strb=0b0001)
    assert not (await apb.read(STATUS)) & RX_OVR
    assert_quiet(dut, CHK)
