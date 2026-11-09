"""Built programs on the ISS: ISA tests and C programs pass, the ISA tests catch injected
model bugs, .hex and .elf loads agree, and random programs run to EXIT 0.
Builds with sw/Makefile first; skipped when the clang toolchain is absent."""
import glob
import os
import shutil
import subprocess

import pytest

import randgen
import rv32_iss
from rv32_iss import Iss

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
BUILD = os.path.join(ROOT, "build", "sw")
TOOLS = os.path.expanduser("~/tools/riscv/bin")
HAVE_CLANG = os.path.exists(os.path.join(TOOLS, "riscv32-unknown-elf-clang"))
ISA = sorted(os.path.splitext(os.path.basename(p))[0]
             for p in glob.glob(os.path.join(ROOT, "sw", "isa", "*.S")))
C_PROGS = sorted(os.path.splitext(os.path.basename(p))[0]
                 for p in glob.glob(os.path.join(ROOT, "sw", "c", "*.c")))

pytestmark = pytest.mark.skipif(not HAVE_CLANG or not shutil.which("make"),
                                reason="RISC-V clang toolchain not installed")


@pytest.fixture(scope="session", autouse=True)
def built():
    if HAVE_CLANG:
        subprocess.run(["make", "-s", "-C", os.path.join(ROOT, "sw"), "all"], check=True,
                       capture_output=True)


def run(name, iss=None, fmt="hex"):
    iss = iss or Iss()
    iss.load(os.path.join(BUILD, name, f"{name}.{fmt}"))
    code = iss.run(2_000_000)
    return iss, code


@pytest.mark.parametrize("name", ISA)
def test_isa_passes(name):
    _, code = run(name)
    assert code == 0, f"{name} failed test {code}"


def test_isa_groups_present():
    assert set(ISA) >= {"alu_reg", "alu_imm", "lui_auipc", "branch", "jump", "load", "store",
                        "csr", "trap", "irq", "muldiv"}


@pytest.mark.parametrize("name", ISA)
def test_isa_cycles_per_step_independent(name):
    _, code = run(name, Iss(cycles_per_step=3))
    assert code == 0


def test_hello():
    iss, code = run("hello")
    assert code == 0
    assert iss.console_text.startswith("Hello from p2-riscv-soc!\n")
    assert "misa=40001100 mhartid=0 dec=-1234 hex=beef str=ok" in iss.console_text
    assert bytes(iss.uart_tx).decode() == iss.console_text


def test_timer_irq():
    iss, code = run("timer_irq")
    assert code == 0 and "got 5 ticks" in iss.console_text


def test_bench():
    iss, code = run("bench")
    assert code == 0 and "bench: PASS" in iss.console_text
    assert "crc32(check)=cbf43926" in iss.console_text


@pytest.mark.parametrize("name", ISA + C_PROGS)
def test_hex_matches_elf(name):
    a, b = Iss(), Iss()
    a.load(os.path.join(BUILD, name, f"{name}.hex"))
    b.load(os.path.join(BUILD, name, f"{name}.elf"))
    assert a.pc == b.pc == 0
    for _ in range(3000):
        if a.halted:
            break
        assert a.step() == b.step()
    assert b.halted == a.halted


# Injected model bugs; each must make the named ISA test fail (the tests can fail).
orig_alu = Iss._alu
orig_trap = Iss._enter_trap
orig_csr_write = Iss._csr_write
orig_bus_write = Iss._bus_write
orig_muldiv = Iss._muldiv


def _bug_mpie(self, cause, tval, epc):
    orig_trap(self, cause, tval, epc)
    self.mstatus_mpie = 0


def _bug_mepc(self, cause, tval, epc):
    orig_trap(self, cause, tval, epc + 4)


def _bug_mie_mask(self, a, v):
    if a == 0x304:
        self.mie = v
    else:
        orig_csr_write(self, a, v)


def _bug_sb_lane(self, addr, data, be):
    orig_bus_write(self, addr, data, 0xF if be == 0x2 else be)


MUTANTS = {
    "sltu": ("_alu", staticmethod(lambda f3, a, b_: int(a > b_) if f3 == 3 else orig_alu(f3, a, b_)),
             "alu_reg"),
    "mpie": ("_enter_trap", _bug_mpie, "trap"),
    "mepc": ("_enter_trap", _bug_mepc, "trap"),
    "mie_mask": ("_csr_write", _bug_mie_mask, "csr"),
    "sb_lane": ("_bus_write", _bug_sb_lane, "store"),
    # MULHSU treating rs2 as signed, and REM by zero returning 0
    "mulhsu": ("_muldiv", staticmethod(lambda f3, a, b_: orig_muldiv(1 if f3 == 2 else f3, a, b_)),
               "muldiv"),
    "rem0": ("_muldiv", staticmethod(lambda f3, a, b_: 0 if f3 == 6 and b_ == 0
                                     else orig_muldiv(f3, a, b_)), "muldiv"),
}


@pytest.mark.parametrize("mutant", sorted(MUTANTS))
def test_isa_tests_detect_model_bugs(mutant, monkeypatch):
    attr, fn, prog = MUTANTS[mutant]
    monkeypatch.setattr(rv32_iss.Iss, attr, fn)
    try:
        _, code = run(prog)
    except rv32_iss.IssError:
        code = -1
    assert code != 0


def test_irq_test_fails_without_interrupts():
    _, code = run("irq", Iss(auto_irq=False))
    assert code != 0


def test_random_programs(tmp_path):
    class A:
        mix, length, build_dir, max_steps = "", 300, str(tmp_path), 200_000
    results = [randgen.build_and_run(seed, A, ROOT) for seed in range(1, 21)]
    bad = [m for ok, m in results if not ok]
    assert not bad, bad


def test_randgen_terminates_and_covers_traps():
    text = randgen.Gen(7, length=1500).program()
    for needle in ("ecall", "jalr", "loop", "sw x", "lw x", "csrr"):
        assert needle in text
    assert randgen.Gen(7, length=50).program() == randgen.Gen(7, length=50).program()
