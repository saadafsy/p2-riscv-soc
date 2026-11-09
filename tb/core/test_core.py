"""cocotb tests for rv32_core.

Every test runs a small self-checking program (tb/core/progs) against the
OBI memory model and checks each RVFI retirement in lockstep against the
reference model (rv_ref.py) and the project's golden ISS (model/rv32_iss.py):
order, pc, rd value, next pc, memory fields. The ISA programs from sw/isa run
against the golden ISS, with its device model behind the data port.
"""
import pathlib
import random
import sys

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, Timer

import build_progs
from obi_mem import Memory, ObiPort, SocMemory
from rv_ref import RefModel

PROJ = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(PROJ / "model"))
from rv32_iss import Iss  # noqa: E402

ISA_TESTS = ("alu_imm", "alu_reg", "branch", "csr", "irq", "jump", "load", "lui_auipc",
             "store", "trap")


def load_hex(path):
    words = [int(w, 16) for w in pathlib.Path(path).read_text().split() if not w.startswith("@")]
    return b"".join(w.to_bytes(4, "little") for w in words)

FIELDS = ("pc_rdata", "insn", "trap", "rs1_addr", "rs2_addr", "rs1_rdata", "rs2_rdata",
          "rd_addr", "rd_wdata", "pc_wdata", "mem_addr", "mem_rmask", "mem_wmask",
          "mem_rdata", "mem_wdata")


class Harness:
    def __init__(self, dut, prog, random_lat=False, irq_noise=False, seed=1, soc=False):
        self.dut = dut
        self.rng = random.Random(seed)
        self.golden = Iss(auto_irq=False)
        self.soc = soc
        if soc:
            # sw/isa program: SoC map, golden ISS only (it also models the peripherals)
            image, self.syms = load_hex(prog), {}
            self.mem = SocMemory(image, Iss(auto_irq=False))
            self.ref = None
        else:
            image, self.syms = build_progs.load(prog)
            self.mem = Memory(image)
            self.ref = RefModel(image)
            self.ref.mip_exact = not irq_noise
        self.golden.ram[: len(image)] = image
        self.ip = ObiPort(dut, "i", self.mem, self.rng, random_lat, writable=False)
        self.dp = ObiPort(dut, "d", self.mem, self.rng, random_lat, writable=True)
        self.irq_noise = irq_noise
        self.noise = [0, 0]
        self.cycle = 0
        self.order = 0
        self.prev = None
        self.retired = []        # (cycle, rvfi record)
        self.interrupts = 0
        self.traps = 0

    async def reset(self):
        d = self.dut
        cocotb.start_soon(Clock(d.clk, 10, unit="ns").start())
        d.rst.value = 1
        for s in ("i_gnt", "i_rvalid", "i_rdata", "d_gnt", "d_rvalid", "d_rdata",
                  "irq_timer", "irq_external"):
            getattr(d, s).value = 0
        for _ in range(5):
            await FallingEdge(d.clk)
        d.rst.value = 0

    def record(self):
        d = self.dut
        r = {f: int(getattr(d, f"rvfi_{f}").value) for f in FIELDS}
        r["order"] = int(d.rvfi_order.value)
        r["intr"] = int(d.rvfi_intr.value)
        return r

    def check(self, rec):
        where = f"order {rec['order']} pc {rec['pc_rdata']:#010x} insn {rec['insn']:#010x}"
        assert rec["order"] == self.order, f"rvfi_order {rec['order']} != {self.order}"
        self.order += 1
        g = self.golden
        if g._handler_entry:
            assert rec["intr"], f"{where}: first handler instruction lacks rvfi_intr"
        elif rec["intr"]:
            # The RTL took an interrupt before this instruction; mirror it.
            cause = int(self.dut.u_csr.mcause.value)
            g.raise_interrupt("external" if cause == 0x8000000B else "timer")
            if self.ref is not None:
                self.ref.take_interrupt(cause)
            self.interrupts += 1
        gr = g.step()
        skip = {"rd_wdata", "mem_rdata"} if gr.nondet else set()
        bad = [f"{f}: rtl {rec[f]:#x} golden {getattr(gr, f):#x}"
               for f in FIELDS + ("intr",) if f not in skip and rec[f] != getattr(gr, f)]
        assert not bad, f"{where} vs golden ISS: " + "; ".join(bad)
        if gr.nondet and gr.rd_addr:
            g.x[gr.rd_addr] = rec["rd_wdata"]
        self.traps += gr.trap
        if self.prev is not None and not rec["intr"]:
            assert rec["pc_rdata"] == self.prev["pc_wdata"], \
                f"{where}: pc_rdata != previous pc_wdata {self.prev['pc_wdata']:#x}"
        if rec["rd_addr"] == 0:
            assert rec["rd_wdata"] == 0, f"{where}: rd_wdata nonzero for x0"
        self.prev = rec
        self.retired.append((self.cycle, rec))
        ref = self.ref
        if ref is None:
            return
        ref.irq_t = int(self.dut.irq_timer.value)
        ref.irq_e = int(self.dut.irq_external.value)
        exp = ref.step(rec)
        bad = [f"{f}: rtl {rec[f]:#x} ref {exp[f]:#x}" for f in FIELDS if rec[f] != exp[f]]
        assert not bad, f"{where}: " + "; ".join(bad)

    def drive_irq(self):
        if self.soc:
            self.mem.tick()
        if self.irq_noise:
            for i in range(2):
                if self.noise[i]:
                    self.noise[i] -= 1
                elif self.rng.random() < 0.03:
                    self.noise[i] = self.rng.randint(1, 6)
        bits = self.mem.irq_bits
        self.dut.irq_timer.value = int(bool(bits & 1 or self.noise[0]))
        self.dut.irq_external.value = int(bool(bits & 2 or self.noise[1]))

    async def run(self, max_cycles=100_000):
        await self.reset()
        d = self.dut
        while self.mem.exit_code is None:
            await FallingEdge(d.clk)
            self.cycle += 1
            assert self.cycle < max_cycles, "timeout"
            self.drive_irq()
            self.ip.drive()
            self.dp.drive()
            await Timer(1, unit="ns")
            self.ip.sample()
            self.dp.sample()
            if int(d.rvfi_valid.value):
                self.check(self.record())
        return self.mem.exit_code

    def retire_cycle(self, sym):
        pc = self.syms[sym]
        return next((i, c) for i, (c, r) in enumerate(self.retired) if r["pc_rdata"] == pc)

    def rate(self, start, end):
        """Cycles per retired instruction from start up to (not including) end."""
        i0, c0 = self.retire_cycle(start)
        i1, c1 = self.retire_cycle(end)
        return (c1 - c0) / (i1 - i0)


async def run_prog(dut, prog, random_lat, **kw):
    h = Harness(dut, prog, random_lat=random_lat, **kw)
    code = await h.run()
    dut._log.info("%s (%s): exit %d, %d retired, %d traps, %d interrupts, %d cycles",
                  prog, "random latency" if random_lat else "fast", code, len(h.retired),
                  h.traps, h.interrupts, h.cycle)
    assert code == 0, f"{prog}: self-check failed at test {code}"
    return h


LAT = ("random_lat", [False, True])


@cocotb.test()
@cocotb.parametrize(LAT)
async def test_alu(dut, random_lat):
    """Integer register-register / immediate ops, LUI, AUIPC, FENCE, WFI."""
    await run_prog(dut, "alu", random_lat)


@cocotb.test()
@cocotb.parametrize(LAT)
async def test_branch(dut, random_lat):
    """All branches taken / not taken, JAL/JALR, back-to-back transfers."""
    await run_prog(dut, "branch", random_lat)


@cocotb.test()
@cocotb.parametrize(LAT)
async def test_mem(dut, random_lat):
    """Loads and stores of each width and offset."""
    await run_prog(dut, "mem", random_lat)


@cocotb.test()
@cocotb.parametrize(LAT)
async def test_hazard(dut, random_lat):
    """Forwarding paths, load-use, branch after load, pointer chasing."""
    await run_prog(dut, "hazard", random_lat)


@cocotb.test()
@cocotb.parametrize(LAT)
async def test_csr(dut, random_lat):
    """CSR read/write/set/clear, field rules, counters."""
    await run_prog(dut, "csr", random_lat)


@cocotb.test()
@cocotb.parametrize(LAT)
async def test_trap(dut, random_lat):
    """ECALL, EBREAK, illegal, misaligned load/store/target, MRET."""
    h = await run_prog(dut, "trap", random_lat)
    assert h.traps == 20, f"expected 20 traps, saw {h.traps}"


@cocotb.test()
@cocotb.parametrize(LAT)
async def test_irq(dut, random_lat):
    """Timer / external interrupts with MIE and mie gating and priority."""
    h = await run_prog(dut, "irq", random_lat)
    assert h.interrupts == 8, f"expected 8 interrupts, saw {h.interrupts}"


@cocotb.test()
@cocotb.parametrize(LAT, ("seed", [1, 2, 3]))
async def test_irq_noise(dut, random_lat, seed):
    """Random interrupt pulses over loads, stores, calls and ECALLs."""
    h = await run_prog(dut, "irq_noise", random_lat, irq_noise=True, seed=seed)
    firsts = [c for c, r in h.retired if r["intr"]][:6]
    dut._log.info("seed %d: first handler entries at cycles %s", seed, firsts)
    assert h.interrupts > 10, f"only {h.interrupts} interrupts were taken"


@cocotb.test()
async def test_cpi(dut):
    """CPI on straight-line code and the load-use / taken-jump penalties."""
    h = await run_prog(dut, "cpi", False)
    cpi = h.rate("cpi_start", "cpi_end")
    lu = h.rate("lu_start", "lu_end")
    br = h.rate("br_start", "br_end")
    dut._log.info("CPI straight-line dependent ALU chain: %.3f", cpi)
    dut._log.info("load+use pair: %.2f cycles per instruction (1 stall per pair)", lu)
    dut._log.info("taken jump: %.2f cycles each (2-cycle penalty)", br)
    assert cpi == 1.0, f"straight-line CPI {cpi}"
    assert lu == 1.5, f"load-use pair costs {lu * 2} cycles, expected 3"
    assert br == 3.0, f"taken jump costs {br} cycles, expected 3"


@cocotb.test()
@cocotb.parametrize(("name", ISA_TESTS), LAT)
async def test_isa(dut, name, random_lat):
    """Project ISA tests (sw/isa, build/sw/<name>/<name>.hex) in lockstep with the golden ISS."""
    hexf = PROJ / "build" / "sw" / name / f"{name}.hex"
    assert hexf.exists(), f"{hexf} missing: run scripts/build_sw.sh"
    await run_prog(dut, str(hexf), random_lat, soc=True)