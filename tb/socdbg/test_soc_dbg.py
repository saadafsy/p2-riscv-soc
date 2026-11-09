"""SoC-level tests for the JTAG debug master, the core hold, the March C-
RAM BIST and the accelerator clock gate (docs/spec.md section 13), on
tb_soc_dbg (soc_top with OBI checkers on every affected link).

- jtag_bus_while_running: bench runs in lockstep with the ISS while JTAG
  reads IDCODE, writes and reads RAM in a region bench does not use, and
  reads/writes GPIO, TIMER, SYSCTL and the accelerator ID. Both masters
  request in the same cycle several times (counted).
- jtag_load_and_boot: JTAG holds the core, loads hello over the debug port,
  checks the image, releases the core; hello then runs in lockstep to EXIT 0.
- mbist_good_and_fault: START is ignored while the core runs; with the core
  held BIST passes on the RAM; with a stuck-at-1 bit forced into one word it
  fails with the expected address, element, background and syndrome.
- clock_gate: clkgate_test (sw/c) in lockstep; the gated accelerator clock
  must have no edge while its synchronized enable is low, the run that was
  frozen mid-way must match p1 attn_fixed.
"""
import os
import pathlib
import random
import subprocess
import sys

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, ReadOnly, RisingEdge

ROOT = pathlib.Path(os.environ.get("P2_ROOT", pathlib.Path(__file__).resolve().parents[2]))
sys.path.insert(0, str(ROOT / "tb/soc"))
sys.path.insert(0, str(ROOT / "tb/debug"))
from jtag_drv import IDCODE, IR_DBG, IR_IDCODE, ST_OK, Jtag  # noqa: E402
from test_soc import check_lockstep, read_hex, reset_soc  # noqa: E402

P1 = pathlib.Path(os.environ.get("P1_ROOT", "/home/saad/p1-attention"))
ACCEL_PERIOD_PS = int(os.environ.get("ACCEL_PERIOD_PS", "13698"))
TCK_PS = 37000  # unrelated to the 10 ns system clock
SW = ROOT / "build/sw"

GPIO_OUT, GPIO_IN = 0x1000_1000, 0x1000_1004
MTIME_LO = 0x1000_2000
SYSCTL = 0x1000_3000
CTRL, STATUS, BIST_CTRL, BIST_STATUS, BIST_ADDR, BIST_SYN, SYS_ID = (
    SYSCTL + o for o in (0x0, 0x4, 0x8, 0xC, 0x10, 0x14, 0x1C))
HOLD, CLK_EN = 1, 2
ACCEL_ID = 0x2000_001C


def val(sig):
    return int(sig.value)


async def start(dut, words, prog=None):
    """Reset with words in RAM; with prog, the lockstep check starts at the
    core's reset release, before the JTAG reset. Returns (jtag, lockstep task)."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    cocotb.start_soon(Clock(dut.accel_clk, ACCEL_PERIOD_PS, unit="ps").start())
    await reset_soc(dut, words, dut.u_soc)
    run = cocotb.start_soon(check_lockstep(dut, str(prog), soc=dut.u_soc)) if prog else None
    j = Jtag(dut, TCK_PS)
    await j.reset()
    return j, run


async def jread(j, addr):
    st, data, a = await j.dbg_read(addr)
    assert st == ST_OK and a == addr, f"JTAG read {addr:#x}: status {st}, addr {a:#x}"
    return data


async def jwrite(j, addr, data):
    st, a = await j.dbg_write(addr, data)
    assert st == ST_OK and a == addr, f"JTAG write {addr:#x}: status {st}, addr {a:#x}"


async def hold_core(j, dut):
    await jwrite(j, CTRL, HOLD | CLK_EN)
    for _ in range(20):
        if await jread(j, STATUS) & 1:
            assert val(dut.u_soc.core_rst) == 1
            return
    raise AssertionError("core not held")


@cocotb.test()
async def jtag_bus_while_running(dut):
    prog = SW / "bench/bench.hex"
    j, run = await start(dut, read_hex(prog), prog)
    soc = dut.u_soc
    both = {"n": 0, "dbg_hs": 0}

    async def contention():
        while True:
            await RisingEdge(dut.clk)
            await ReadOnly()
            if val(soc.d_req) and val(soc.dbg_req):
                both["n"] += 1
            if val(soc.dbg_req) and val(soc.dbg_gnt):
                both["dbg_hs"] += 1
    cocotb.start_soon(contention())

    assert await j.ir(IR_IDCODE) == 0b00001
    assert await j.dr(0, 32) == IDCODE
    await j.ir(IR_DBG)
    rng = random.Random(7)
    dut.gpio_in.value = 0x1A5A5
    region = [0x8000 + 4 * i for i in range(24)]  # bench ends at 0x2cf0 (bss)
    ref = {}
    for rnd in range(3):
        for a in region:
            ref[a] = rng.getrandbits(32)
            await jwrite(j, a, ref[a])
        for a in rng.sample(region, len(region)):
            assert await jread(j, a) == ref[a], f"RAM {a:#x}"
        assert await jread(j, GPIO_IN) == 0x1A5A5
        await jwrite(j, GPIO_OUT, 0x5A00 | rnd)
        assert await jread(j, GPIO_OUT) == 0x5A00 | rnd
        assert val(dut.gpio_out) == 0x5A00 | rnd
        t0 = await jread(j, MTIME_LO)
        t1 = await jread(j, MTIME_LO)
        assert t1 > t0
        assert await jread(j, ACCEL_ID) == 0x4154544E
        assert await jread(j, SYS_ID) == 0x53595343
        assert await jread(j, STATUS) == 0b10  # core running, accel clock on
        if run.done():
            break
    retired, cycles = await run
    for a in region:
        assert val(soc.u_ram.mem[a >> 2]) == ref[a]
    dut._log.info(f"bench PASS in lockstep ({retired} retired, {cycles} cycles); "
                  f"{both['dbg_hs']} JTAG bus transfers, {both['n']} cycles with both masters "
                  f"requesting")
    assert both["n"] > 0, "no cycle with both masters requesting: arbitration not exercised"


@cocotb.test()
async def jtag_load_and_boot(dut):
    prog = SW / "hello/hello.hex"
    words = read_hex(prog)
    j, _ = await start(dut, [])  # RAM all zero: the core traps in a loop at 0
    soc = dut.u_soc
    await ClockCycles(dut.clk, 50)
    await j.ir(IR_DBG)
    await hold_core(j, dut)
    image = [(4 * i, w) for i, w in enumerate(words) if w]
    for a, w in image:
        await jwrite(j, a, w)
    for a, w in image[:: max(1, len(image) // 16)]:
        assert await jread(j, a) == w
    for i, w in enumerate(words):
        assert val(soc.u_ram.mem[i]) == w, f"word {i}"
    run = cocotb.start_soon(check_lockstep(dut, str(prog), soc=soc))
    await jwrite(j, CTRL, CLK_EN)
    retired, cycles = await run
    dut._log.info(f"loaded {len(image)} words over JTAG; hello PASS in lockstep after "
                  f"release ({retired} retired)")


async def bist_wait(j, dut, limit=2000):
    for _ in range(limit):
        st = await jread(j, BIST_STATUS)
        if not st & 1:
            return st
        await ClockCycles(dut.clk, 20000)
    raise AssertionError("BIST did not finish")


@cocotb.test()
async def mbist_good_and_fault(dut):
    j, _ = await start(dut, [])
    soc = dut.u_soc
    await j.ir(IR_DBG)
    # START while the core runs is ignored.
    await jwrite(j, BIST_CTRL, 1)
    assert await jread(j, BIST_STATUS) == 0
    await hold_core(j, dut)
    # A word of junk, to see BIST overwrite it.
    soc.u_ram.mem[100].value = 0xDEADBEEF
    await jwrite(j, BIST_CTRL, 1)
    st = await bist_wait(j, dut)
    assert st == 0b010, f"good RAM: BIST_STATUS {st:#x}"
    assert all(val(soc.u_ram.mem[i]) == 0 for i in range(0, 1 << 14, 97))
    assert val(soc.u_ram.mem[100]) == 0

    # Stuck-at-1 on bit 17 of word K, forced after every clock edge.
    k, bit = 0x3ABC, 17
    mask = 1 << bit
    stop = {"v": False}

    async def stuck_at_1():
        while not stop["v"]:
            await FallingEdge(dut.clk)
            w = val(soc.u_ram.mem[k])
            if not w & mask:
                soc.u_ram.mem[k].value = w | mask
    cocotb.start_soon(stuck_at_1())
    await jwrite(j, BIST_CTRL, 1)
    for _ in range(200000):
        await RisingEdge(dut.clk)
        if val(soc.bist_fail):
            break
    stop["v"] = True
    st = await bist_wait(j, dut)
    elem, bg = (st >> 4) & 7, (st >> 8) & 7
    addr, syn = await jread(j, BIST_ADDR), await jread(j, BIST_SYN)
    dut._log.info(f"fault run: STATUS {st:#x} addr {addr:#x} elem {elem} bg {bg} syn {syn:#x}")
    assert st & 0b111 == 0b110, f"faulty RAM: BIST_STATUS {st:#x}"
    # M0 writes 0, M1 (r0, w1) reads the stuck 1 first.
    assert (addr, elem, bg, syn) == (4 * k, 1, 0, mask)
    # Release: the core restarts (on a zeroed RAM it just traps).
    await jwrite(j, CTRL, CLK_EN)
    assert await jread(j, STATUS) & 1 == 0


def elf_symbols(elf):
    nm = pathlib.Path.home() / "tools/riscv/bin/llvm-nm"
    out = subprocess.run([str(nm), str(elf)], capture_output=True, text=True, check=True).stdout
    return {f[2]: int(f[0], 16) for f in (l.split() for l in out.splitlines()) if len(f) == 3}


def ram_bytes(soc, addr, n):
    out = []
    for a in range(addr, addr + n):
        w = val(soc.u_ram.mem[a >> 2])
        b = (w >> (8 * (a & 3))) & 0xFF
        out.append(b - 256 if b > 127 else b)
    return out


@cocotb.test()
async def clock_gate(dut):
    prog = SW / "clkgate_test/clkgate_test.hex"
    _, run = await start(dut, read_hex(prog), prog)
    soc = dut.u_soc
    g = {"edges": 0, "gated": 0, "bad": 0}

    async def gclk_edges():
        while True:
            await RisingEdge(soc.accel_gclk)
            g["edges"] += 1

    async def check_gate():
        prev_en, prev_edges = 1, 0
        while True:
            await RisingEdge(dut.accel_clk)
            await ReadOnly()
            # en_s low after edge k means the latch blocks edge k + 1.
            if prev_en == 0:
                g["gated"] += 1
                if g["edges"] != prev_edges:
                    g["bad"] += 1
            prev_en, prev_edges = val(soc.accel_en_s), g["edges"]
    cocotb.start_soon(gclk_edges())
    cocotb.start_soon(check_gate())
    retired, cycles = await run
    dut._log.info(f"clkgate_test PASS in lockstep ({retired} retired); accel clock "
                  f"{g['gated']} cycles gated, {g['bad']} gated-clock edges while disabled, "
                  f"{g['edges']} gated-clock edges in all")
    assert g["bad"] == 0
    assert g["gated"] > 1000, "clock was not gated during the frozen run"

    sys.path.insert(0, str(P1 / "model"))
    import attn
    sym = elf_symbols(SW / "clkgate_test/clkgate_test.elf")
    n, d = 16, 16
    mats = [ram_bytes(soc, sym[s], n * d) for s in ("q_m", "k_m", "v_m", "out_b")]
    q, k, v = ([m[r * d:(r + 1) * d] for r in range(n)] for m in mats[:3])
    exp = [x for row in attn.attn_fixed(q, k, v, attn.gen_exp_lut()) for x in row]
    assert mats[3] == exp, "run frozen by the clock gate differs from attn_fixed"
