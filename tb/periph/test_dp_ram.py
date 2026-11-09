"""dp_ram: $readmemh init, byte enables, READ_FIRST, both ports at full rate."""

import random

import cocotb

from tbutil import ObiMaster, assert_quiet, start

AW = 10
WORDS = 1 << AW
CHK = ["chk_a", "chk_b"]


def init_word(i):
    """Must match the image written by run.py."""
    return (i * 0x9E3779B1 + 0x1234) & 0xFFFFFFFF


IDLE = {"a_req": 0, "a_addr": 0, "b_req": 0, "b_addr": 0, "b_we": 0, "b_be": 0, "b_wdata": 0}


@cocotb.test()
async def test_init_image_both_ports(dut):
    await start(dut, IDLE)
    a = ObiMaster(dut, "a_", read_only=True)
    b = ObiMaster(dut, "b_")
    idx = list(range(0, WORDS, 7)) + [WORDS - 1]
    ra = cocotb.start_soon(a.run([(i * 4, 0, 0xF, 0) for i in idx]))
    rb = cocotb.start_soon(b.run([(i * 4, 0, 0xF, 0) for i in reversed(idx)]))
    assert await ra == [init_word(i) for i in idx]
    assert await rb == [init_word(i) for i in reversed(idx)]
    # one access per cycle on each port, plus the final response cycle
    assert a.cycles == len(idx) + 1 and b.cycles == len(idx) + 1, (a.cycles, b.cycles)
    assert_quiet(dut, CHK)


@cocotb.test()
async def test_byte_enables_read_first(dut):
    await start(dut, IDLE)
    b = ObiMaster(dut, "b_")
    a = ObiMaster(dut, "a_", read_only=True)
    w = 5
    old = init_word(w)
    # a write's response carries the old word (READ_FIRST)
    await b.run([(w * 4, 1, 0b0101, 0xAABBCCDD)])
    exp = (old & 0xFF00FF00) | 0x00BB00DD
    assert await b.read(w * 4) == exp
    assert await a.read(w * 4) == exp, "port A sees port B writes"
    assert await b.read(w * 4 + 3) == exp, "low address bits ignored"
    assert await b.read((w + WORDS) * 4) == exp, "address aliases above 2^AW words"
    assert_quiet(dut, CHK)


@cocotb.test()
async def test_random_traffic(dut):
    await start(dut, IDLE)
    rng = random.Random(11)
    b = ObiMaster(dut, "b_", seed=3)
    a = ObiMaster(dut, "a_", read_only=True, seed=4)
    model = [init_word(i) for i in range(WORDS)]
    # word 5 was written by an earlier test; keep it out of both sets
    hot = rng.sample([i for i in range(WORDS) if i != 5], 24)  # reads hit written words
    txns, exp = [], []
    for _ in range(600):
        w = rng.choice(hot)
        if rng.random() < 0.5:
            be = rng.getrandbits(4)
            data = rng.getrandbits(32)
            txns.append((w * 4, 1, be, data))
            exp.append(None)
            for lane in range(4):
                if be >> lane & 1:
                    mask = 0xFF << (8 * lane)
                    model[w] = (model[w] & ~mask) | (data & mask)
        else:
            txns.append((w * 4, 0, 0xF, 0))
            exp.append(model[w])
    # port A fetches concurrently from words B never writes
    cold = [i for i in range(WORDS) if i not in hot and i != 5][:300]
    ra = cocotb.start_soon(a.run([(i * 4, 0, 0xF, 0) for i in cold], idle_prob=0.3))
    assert await b.run(txns, idle_prob=0.2) == exp
    assert await ra == [init_word(i) for i in cold]
    assert_quiet(dut, CHK)
