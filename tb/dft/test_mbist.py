"""mbist_marchc on fault_mem: a good memory passes; every injected fault is
caught, and fail_addr / fail_elem / fail_bg / fail_syn match the reference
model (march_ref.py) for the first failing read. Grant and response
latency are random throughout; the OBI checker in tb_mbist watches the link.
"""

import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, ReadOnly, RisingEdge

import march_ref as ref
from march_ref import AF, CFID, CFIN, CFST, NONE, SA0, SA1, TF_DN, TF_UP, Fault

AW = int(os.environ.get("MBIST_AW", "5"))
NBG = int(os.environ.get("MBIST_NBG", "6"))
N = 1 << AW


def val(sig):
    return int(sig.value)


async def stall_driver(dut, rng, p_gnt, p_rsp):
    while True:
        await FallingEdge(dut.clk)
        dut.gnt_ok.value = int(rng.random() < p_gnt)
        dut.rsp_ok.value = int(rng.random() < p_rsp)


async def setup(dut, seed, p_gnt=0.6, p_rsp=0.6):
    rng = random.Random(seed)
    for s in ("start", "clr", "f_type", "f_vaddr", "f_vbit", "f_aaddr", "f_abit", "f_up", "f_val"):
        getattr(dut, s).value = 0
    dut.gnt_ok.value = 1
    dut.rsp_ok.value = 1
    dut.rst.value = 1
    Clock(dut.clk, 10, unit="ns").start()
    await ClockCycles(dut.clk, 3)
    await FallingEdge(dut.clk)
    dut.rst.value = 0
    cocotb.start_soon(stall_driver(dut, rng, p_gnt, p_rsp))
    return rng


def inject(dut, f):
    dut.f_type.value = f.kind
    dut.f_vaddr.value = f.vaddr
    dut.f_vbit.value = f.vbit
    dut.f_aaddr.value = f.aaddr
    dut.f_abit.value = f.abit
    dut.f_up.value = f.up
    dut.f_val.value = f.val


async def run_bist(dut, f, max_cycles=200000):
    await FallingEdge(dut.clk)
    inject(dut, f)
    dut.clr.value = 1
    await FallingEdge(dut.clk)
    dut.clr.value = 0
    dut.start.value = 1
    await FallingEdge(dut.clk)
    dut.start.value = 0
    await ReadOnly()
    assert val(dut.busy) == 1 and val(dut.done) == 0
    for _ in range(max_cycles):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if val(dut.done):
            assert val(dut.busy) == 0
            return
    raise AssertionError("MBIST did not finish")


async def check(dut, f):
    """Run one BIST pass with fault f and compare with the reference."""
    await run_bist(dut, f)
    acc, first = ref.run_march(AW, NBG, f)
    assert val(dut.n_access) == acc == 10 * N * NBG
    got_fail = val(dut.fail)
    if first is None:
        assert got_fail == 0, f"{ref.NAMES[f.kind]} {f}: unexpected fail"
        return None
    exp = first
    got = (val(dut.fail_addr), val(dut.fail_elem), val(dut.fail_bg), val(dut.fail_syn))
    assert got_fail == 1, f"{ref.NAMES[f.kind]} {f}: fault not detected"
    assert got == exp, f"{ref.NAMES[f.kind]} {f}: got {got} expected {exp}"
    return got


@cocotb.test()
async def good_memory_passes(dut):
    """No fault: pass, done held, access count 10 * 2^AW * NBG; run twice."""
    await setup(dut, 1)
    for _ in range(2):
        assert await check(dut, Fault()) is None
        await ClockCycles(dut.clk, 5)
        assert val(dut.done) == 1 and val(dut.fail) == 0


@cocotb.test()
async def zero_latency_passes(dut):
    """Slave that always grants and answers next cycle: 2 cycles per access."""
    await setup(dut, 2, p_gnt=1.0, p_rsp=1.0)
    await FallingEdge(dut.clk)
    inject(dut, Fault())
    dut.start.value = 1
    await FallingEdge(dut.clk)
    dut.start.value = 0
    cycles = 1
    while True:
        await RisingEdge(dut.clk)
        await ReadOnly()
        if val(dut.done):
            break
        cycles += 1
    assert val(dut.fail) == 0
    assert cycles == 2 * 10 * N * NBG, cycles


def rand_cell(rng):
    return rng.randrange(N), rng.randrange(32)


@cocotb.test()
async def stuck_at_faults(dut):
    """SA0 / SA1 at random cells, plus the first and last word."""
    rng = await setup(dut, 3)
    cells = [(0, 0), (N - 1, 31)] + [rand_cell(rng) for _ in range(3)]
    for kind in (SA0, SA1):
        for a, b in cells:
            await check(dut, Fault(kind, a, b))


@cocotb.test()
async def transition_faults(dut):
    """Rising and falling transition faults."""
    rng = await setup(dut, 4)
    for kind in (TF_UP, TF_DN):
        for _ in range(4):
            a, b = rand_cell(rng)
            await check(dut, Fault(kind, a, b))


@cocotb.test()
async def coupling_faults_inter_word(dut):
    """CFin, CFid (all four kinds) and CFst with aggressor above and below the victim."""
    rng = await setup(dut, 5)
    for kind in (CFIN, CFID, CFST):
        for up in (0, 1):
            for v in ((0, 1) if kind != CFIN else (0,)):
                for _ in range(2):
                    va, vb = rand_cell(rng)
                    aa = rng.choice([x for x in range(N) if x != va])
                    await check(dut, Fault(kind, va, vb, aa, rng.randrange(32), up, v))


@cocotb.test()
async def coupling_faults_intra_word(dut):
    """Victim and aggressor bits in the same word: needs the extra backgrounds."""
    rng = await setup(dut, 6)
    missed = 0
    for kind in (CFIN, CFID):
        for up in (0, 1):
            for v in (0, 1):
                va, vb = rand_cell(rng)
                ab = rng.choice([x for x in range(32) if x != vb])
                if await check(dut, Fault(kind, va, vb, va, ab, up, v)) is None:
                    missed += 1
    dut._log.info(f"intra-word coupling faults missed: {missed}/8 with NBG={NBG}")
    if NBG == 6:
        assert missed == 0, "intra-word coupling escaped with all backgrounds"


@cocotb.test()
async def address_faults(dut):
    """Address decoder fault: one address aliases another."""
    rng = await setup(dut, 7)
    for _ in range(4):
        va = rng.randrange(N)
        aa = rng.choice([x for x in range(N) if x != va])
        await check(dut, Fault(AF, va, 0, aa, 0))


@cocotb.test()
async def restart_clears_fail(dut):
    """A failing run, then the fault is removed: the next run passes and clears fail_*."""
    await setup(dut, 8)
    await check(dut, Fault(SA1, 3, 7))
    assert val(dut.fail) == 1
    assert await check(dut, Fault(NONE)) is None
    assert val(dut.fail_addr) == 0 and val(dut.fail_syn) == 0
