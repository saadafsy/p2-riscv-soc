"""Board firmware on the UART pin: runs build/sw/board/board.hex (make -C sw
board) on soc_top, decodes uart_tx as 8N1 serial and checks that the text a
terminal on the Basys 3 would show ends in "attn_test: PASS".

    make board            (from the repo root)
    BOARD_HEX=<other.hex> runs another image; the sim-only attn_test must fail.

The Makefile builds with UART_DIV=16, so one bit is 16 clk cycles here; on the
board the divisor is CLK_HZ / 115200 and the text is the same.
"""
import os
import pathlib

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge

from test_soc import ACCEL_PERIOD_PS, ROOT, read_hex, reset_soc

BIT = 16  # clk cycles per bit, matches -GUART_DIV=16 in the Makefile
MAX_CYCLES = int(os.environ.get("MAX_CYCLES", "6000000"))


async def uart_monitor(dut, out):
    while True:
        await FallingEdge(dut.uart_tx)  # start bit
        await ClockCycles(dut.clk, BIT // 2)
        assert int(dut.uart_tx.value) == 0, "start bit glitch"
        byte = 0
        for i in range(8):
            await ClockCycles(dut.clk, BIT)
            byte |= int(dut.uart_tx.value) << i
        await ClockCycles(dut.clk, BIT)
        assert int(dut.uart_tx.value) == 1, f"framing error after byte 0x{byte:02x}"
        out.append(chr(byte))


@cocotb.test()
async def board_uart(dut):
    hexpath = pathlib.Path(os.environ.get("BOARD_HEX") or ROOT / "build/sw/board/board.hex")
    assert hexpath.exists(), f"{hexpath} missing: run make -C sw board"
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    cocotb.start_soon(Clock(dut.accel_clk, ACCEL_PERIOD_PS, unit="ps").start())
    await reset_soc(dut, read_hex(hexpath))
    text = []
    cocotb.start_soon(uart_monitor(dut, text))
    for _ in range(MAX_CYCLES // 1000):
        await ClockCycles(dut.clk, 1000)
        s = "".join(text)
        if "attn_test: PASS\n" in s or "attn_test: FAIL" in s:
            break
    s = "".join(text)
    for line in s.splitlines():
        dut._log.info(f"uart> {line}")
    assert "attn_test: PASS\n" in s, "no PASS line on the UART"
    assert s.count("0 mismatches") == 3, "expected three runs with 0 mismatches"
