"""Lockstep test: every retired instruction of soc_top (RVFI) against the ISS.

Timing-dependent reads (peripheral registers, cycle counters) cannot match an
untimed model, so for those every field except the read value is compared and
the RTL's value is copied into the ISS. Interrupts are injected into the ISS at
the record where the RTL took them.
"""
import glob
import os
import pathlib
import sys

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge, Timer

ROOT = pathlib.Path(os.environ.get("P2_ROOT", pathlib.Path(__file__).resolve().parents[2]))
sys.path.insert(0, str(ROOT / "model"))
from rv32_iss import Iss  # noqa: E402

FIELDS = ["insn", "trap", "intr", "rs1_addr", "rs2_addr", "rs1_rdata", "rs2_rdata",
          "rd_addr", "rd_wdata", "pc_rdata", "pc_wdata", "mem_addr", "mem_rmask",
          "mem_wmask", "mem_rdata", "mem_wdata"]
PERIPH_LO, PERIPH_HI = 0x1000_0000, 0x1000_EFFF
ACCEL_LO, ACCEL_HI = 0x2000_0000, 0x2000_FFFF  # accelerator, not modeled by the ISS
ACCEL_PERIOD_PS = int(os.environ.get("ACCEL_PERIOD_PS", "13698"))  # 73 MHz; sys is 100
MAX_CYCLES = int(os.environ.get("MAX_CYCLES", "4000000"))


def programs():
    sel = os.environ.get("PROGS", "")
    prog_dir = pathlib.Path(os.environ.get("PROG_DIR") or ROOT / "build/sw")
    hexes = sorted(glob.glob(str(prog_dir / "*/*.hex")))
    if sel:
        want = set(sel.split(","))
        hexes = [h for h in hexes if pathlib.Path(h).stem in want]
    return hexes


def rtl_record(core):
    r = {f: int(getattr(core, "rvfi_" + f).value) for f in FIELDS}
    r["order"] = int(core.rvfi_order.value)
    return r


def find(handle, *paths):
    for p in paths:
        h = handle
        try:
            for part in p.split("."):
                h = getattr(h, part)
            return h
        except AttributeError:
            continue
    return None


def read_hex(hexpath):
    return [int(l, 16) for l in pathlib.Path(hexpath).read_text().split()]


async def reset_soc(dut, words, soc=None):
    """Power-on reset of all domains with the RAM preloaded. The JTAG pins
    are driven idle; trst is applied with a few TCK pulses (it is synchronous
    to TCK) and released with rst, as rtl/debug/README.md requires."""
    soc = dut if soc is None else soc
    dut.rst.value = 1
    dut.dbg_rst.value = 1
    dut.accel_rst.value = 1
    dut.uart_rx.value = 1
    dut.gpio_in.value = 0
    dut.trst.value = 1
    dut.tms.value = 1
    dut.tdi.value = 0
    dut.tck.value = 0
    for i in range(1 << 14):
        soc.u_ram.mem[i].value = words[i] if i < len(words) else 0
    for _ in range(3):
        await Timer(20, unit="ns")
        dut.tck.value = 1
        await Timer(20, unit="ns")
        dut.tck.value = 0
    for _ in range(5):
        await RisingEdge(dut.clk)
    for _ in range(3):
        await RisingEdge(dut.accel_clk)
    dut.accel_rst.value = 0
    await RisingEdge(dut.clk)
    dut.rst.value = 0
    dut.dbg_rst.value = 0
    dut.trst.value = 0


async def run_program(dut, hexpath):
    await reset_soc(dut, read_hex(hexpath))
    return await check_lockstep(dut, hexpath)


async def check_lockstep(dut, hexpath, soc=None, max_cycles=MAX_CYCLES):
    """Compare every retirement with the ISS, starting with the core fresh out of
    reset (or held in it), until SIMCTRL EXIT."""
    soc = dut if soc is None else soc
    iss = Iss(auto_irq=False)
    iss.load_hex(hexpath)
    core = soc.u_core
    mcause = find(core, "u_csr.mcause", "u_csr.mcause_q", "csr_mcause", "mcause")
    prev_trap, retired, history = 0, 0, []
    for cycle in range(max_cycles):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if int(core.rvfi_valid.value):
            rtl = rtl_record(core)
            if rtl["intr"] and not prev_trap:
                cause = int(mcause.value) if mcause is not None else 0x80000007
                iss.raise_interrupt("external" if (cause & 0x7FFFFFFF) == 11 else "timer")
            exp = vars(iss.step())
            periph = rtl["mem_rmask"] and (PERIPH_LO <= rtl["mem_addr"] <= PERIPH_HI
                                           or ACCEL_LO <= rtl["mem_addr"] <= ACCEL_HI)
            skip = {"rd_wdata", "mem_rdata"} if (exp.get("nondet") or periph) else set()
            bad = [f for f in FIELDS if f not in skip and rtl[f] != (exp[f] or 0)]
            if rtl["order"] != retired:
                bad.append("order")
            history = (history + [(rtl, exp)])[-8:]
            if bad:
                lines = [f"{f}: rtl={rtl.get(f, 0):#x} iss={(exp.get(f) or 0):#x}" for f in bad]
                ctx = "\n".join(f"  pc={r['pc_rdata']:08x} insn={r['insn']:08x}" for r, _ in history)
                raise AssertionError(
                    f"{pathlib.Path(hexpath).stem}: mismatch at retire {retired} "
                    f"(pc {rtl['pc_rdata']:#010x}, insn {rtl['insn']:#010x}):\n  "
                    + "\n  ".join(lines) + "\nlast retires:\n" + ctx)
            if skip and rtl["rd_addr"]:
                iss.x[rtl["rd_addr"]] = rtl["rd_wdata"]
            prev_trap = rtl["trap"]
            retired += 1
        if int(soc.u_simctrl.exit_seen.value):
            code = int(soc.u_simctrl.exit_code.value)
            assert code == 0, f"{pathlib.Path(hexpath).stem}: program exit code {code}"
            return retired, cycle + 1
    raise AssertionError(f"{pathlib.Path(hexpath).stem}: no EXIT within {max_cycles} cycles")


@cocotb.test()
@cocotb.parametrize(prog=programs())
async def lockstep(dut, prog):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    cocotb.start_soon(Clock(dut.accel_clk, ACCEL_PERIOD_PS, unit="ps").start())
    retired, cycles = await run_program(dut, prog)
    dut._log.info(f"{pathlib.Path(prog).stem}: PASS, {retired} instructions in {cycles} "
                  f"cycles (CPI {cycles / max(retired, 1):.2f})")
