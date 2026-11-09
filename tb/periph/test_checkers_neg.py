"""Negative tests: each checker rule must fire on a deliberately bad sequence
and stay silent on a legal one. Run with +verilator+error+limit so a failing
assertion does not stop the simulation; run.py also counts the assertion
messages in the log."""

import cocotb
from cocotb.triggers import ClockCycles, FallingEdge

from tbutil import start, val

IDLE = {"req": 0, "gnt": 0, "addr": 0, "we": 0, "be": 0, "wdata": 0, "rvalid": 0,
        "psel": 0, "penable": 0, "pwrite": 0, "paddr": 0, "pwdata": 0, "pstrb": 0, "pprot": 0,
        "pready": 0}

OBI_M1, OBI_S1, OBI_S2 = 0, 1, 2
A1, A2, A3, A4, A5, A6, A7, A8, A9 = range(9)


async def drive(dut, cycles):
    """cycles: list of dicts of signal values, one per clock; unspecified
    signals keep their previous value."""
    for c in cycles:
        await FallingEdge(dut.clk)
        for k, v in c.items():
            getattr(dut, k).value = v
    await FallingEdge(dut.clk)
    for k, v in IDLE.items():
        getattr(dut, k).value = v
    await ClockCycles(dut.clk, 2)


def fired(dut):
    return val(dut.chk_obi.fired), val(dut.chk_apb.fired)


async def expect(dut, cycles, obi_rule=None, apb_rule=None):
    await start(dut, IDLE)
    await drive(dut, cycles)
    fo, fa = fired(dut)
    if obi_rule is None and apb_rule is None:
        assert (fo, fa) == (0, 0), f"legal sequence flagged: obi {fo:#x} apb {fa:#x}"
    if obi_rule is not None:
        assert fo >> obi_rule & 1, f"OBI rule {obi_rule} did not fire (mask {fo:#x})"
    if apb_rule is not None:
        assert fa >> apb_rule & 1, f"APB rule {apb_rule} did not fire (mask {fa:#x})"


SETUP = {"psel": 1, "penable": 0, "paddr": 0x4, "pwrite": 1, "pwdata": 0x55, "pstrb": 0b0101}
ACC_WAIT = {"penable": 1, "pready": 0}
ACC_DONE = {"penable": 1, "pready": 1}


@cocotb.test()
async def test_legal_sequences_quiet(dut):
    await expect(dut, [
        {"req": 1, "gnt": 0, "addr": 0x10, "we": 1, "be": 0xF, "wdata": 7},
        {"gnt": 1},
        {"req": 1, "gnt": 1, "addr": 0x20, "rvalid": 1},  # next request in rvalid cycle
        {"req": 0, "gnt": 0, "rvalid": 1},
        {"rvalid": 0} | SETUP,
        ACC_WAIT, ACC_DONE,
        {"psel": 2, "penable": 0, "paddr": 0x8, "pready": 0},  # back-to-back SETUP
        {"penable": 1, "pready": 2},
        {"psel": 1, "penable": 0, "pwrite": 0, "pstrb": 0, "pready": 0},  # read, pstrb 0
        {"penable": 1, "pready": 1},
        {"psel": 0, "penable": 0, "pwrite": 1, "pstrb": 0b1111},  # strobes free when idle
        {"psel": 0, "penable": 0, "pwrite": 0, "pstrb": 0},
    ])


@cocotb.test()
async def test_obi_m1_addr_changes_before_gnt(dut):
    await expect(dut, [{"req": 1, "addr": 0x10}, {"addr": 0x14, "gnt": 1}], obi_rule=OBI_M1)


@cocotb.test()
async def test_obi_m1_req_dropped_before_gnt(dut):
    await expect(dut, [{"req": 1, "addr": 0x10}, {"req": 0}], obi_rule=OBI_M1)


@cocotb.test()
async def test_obi_s1_rvalid_without_request(dut):
    await expect(dut, [{"rvalid": 1}], obi_rule=OBI_S1)


@cocotb.test()
async def test_obi_s1_rvalid_same_cycle_as_gnt(dut):
    await expect(dut, [{"req": 1, "gnt": 1, "rvalid": 1}], obi_rule=OBI_S1)


@cocotb.test()
async def test_obi_s2_two_outstanding(dut):
    await expect(dut, [{"req": 1, "gnt": 1}, {"req": 1, "gnt": 1, "addr": 4}], obi_rule=OBI_S2)


@cocotb.test()
async def test_apb_a1_two_psel(dut):
    await expect(dut, [{"psel": 0b0110}], apb_rule=A1)


@cocotb.test()
async def test_apb_a2_penable_without_psel(dut):
    await expect(dut, [{"penable": 1}], apb_rule=A2)


@cocotb.test()
async def test_apb_a3_setup_not_followed_by_access(dut):
    await expect(dut, [SETUP, {"psel": 0}], apb_rule=A3)


@cocotb.test()
async def test_apb_a4_access_without_setup(dut):
    await expect(dut, [{"psel": 1, "penable": 1, "pready": 1}], apb_rule=A4)


@cocotb.test()
async def test_apb_a5_paddr_changes_in_access(dut):
    await expect(dut, [SETUP, ACC_WAIT, {"paddr": 0x8}], apb_rule=A5)


@cocotb.test()
async def test_apb_a5_pwdata_changes_in_access(dut):
    await expect(dut, [SETUP, {"penable": 1, "pready": 1, "pwdata": 0x66}], apb_rule=A5)


@cocotb.test()
async def test_apb_a6_penable_drops_while_waiting(dut):
    await expect(dut, [SETUP, ACC_WAIT, {"penable": 0}], apb_rule=A6)


@cocotb.test()
async def test_apb_a7_penable_held_after_done(dut):
    await expect(dut, [SETUP, ACC_DONE, {"pready": 0}], apb_rule=A7)


@cocotb.test()
async def test_apb_a8_pstrb_changes_in_access(dut):
    await expect(dut, [SETUP, {"penable": 1, "pready": 1, "pstrb": 0b0001}], apb_rule=A8)


@cocotb.test()
async def test_apb_a8_pprot_changes_while_waiting(dut):
    await expect(dut, [SETUP, ACC_WAIT, {"pprot": 0b010}], apb_rule=A8)


@cocotb.test()
async def test_apb_a9_pstrb_on_read(dut):
    await expect(dut, [{"psel": 1, "penable": 0, "pwrite": 0, "pstrb": 0b0010}, ACC_DONE],
                 apb_rule=A9)
