#!/usr/bin/env python3
"""Random RV32IM program generator (assembly for clang) for ISS/RTL lockstep runs.

Programs always terminate: control flow only goes forward, except bounded loops whose
counter (x30) the body never writes. Loads and stores use base x31 = DATA_BASE + 0x800,
so every address lies in RAM 0x8000-0x8FFF. Traps (ecall, ebreak, illegal, misaligned
data and jump targets) are resumed at mepc + 4 by a handler that uses only x29. The run
ends by storing x1-x28 to SIG_BASE and writing 0 to SIMCTRL EXIT.

  randgen.py --seed 1 -o prog.S                 one program
  randgen.py --batch 50 --seed 1                generate, build and run 50 on the ISS
  --mix alu=30,imm=20,load=10,...  --length N   instruction mix and body size
"""
import argparse
import os
import random
import subprocess
import sys

DATA_BASE = 0x8000
SIG_BASE = 0x9000
SIMCTRL_EXIT = 0x1000F000

DEFAULT_MIX = dict(alu=30, imm=20, upper=4, load=12, store=10, branch=10, jal=3, jalr=3,
                   csr=3, misc=2, trap=3, muldiv=8)
R_OPS = ["add", "sub", "sll", "slt", "sltu", "xor", "srl", "sra", "or", "and"]
I_OPS = ["addi", "slti", "sltiu", "xori", "ori", "andi"]
SH_OPS = ["slli", "srli", "srai"]
M_OPS = ["mul", "mulh", "mulhsu", "mulhu", "div", "divu", "rem", "remu"]
BR_OPS = ["beq", "bne", "blt", "bge", "bltu", "bgeu"]
LOADS = {"lb": 1, "lbu": 1, "lh": 2, "lhu": 2, "lw": 4}
STORES = {"sb": 1, "sh": 2, "sw": 4}
INTERESTING = [0, 1, 2, -1, -2, 0x7FFFFFFF, -0x80000000, 0x80000001, 0xFF, 0xFFFF, 0x55555555,
               0xAAAAAAAA, 31, 32, 33]


class Gen:
    def __init__(self, seed, mix=None, length=400, loop_prob=0.15, block=12):
        self.rng = random.Random(seed)
        self.seed = seed
        self.mix = dict(DEFAULT_MIX, **(mix or {}))
        self.length = length
        self.loop_prob = loop_prob
        self.block = block
        self.nblk = 0

    def rd(self):
        return f"x{self.rng.choice([0] + list(range(1, 29)) * 4)}"

    def rs(self):
        return f"x{self.rng.choice(list(range(0, 29)) + [31])}"

    def imm12(self):
        r = self.rng
        return r.choice([r.randint(-2048, 2047), r.choice([0, 1, -1, 2047, -2048, 0x7FF, -0x800])])

    def mem_off(self, size, misalign):
        off = self.rng.randrange(-2048, 2048 - size, size)
        if misalign:
            off += self.rng.randrange(1, size)
        return off

    def item(self, kind, idx, nitems, lbl):
        """One instruction (or a short fixed group). Branch targets stay in the block."""
        r = self.rng
        fwd = lambda: lbl(r.randint(idx + 1, min(nitems, idx + 8)))  # noqa: E731
        if kind == "alu":
            return [f"{r.choice(R_OPS)} {self.rd()}, {self.rs()}, {self.rs()}"]
        if kind == "muldiv":
            # Mostly random registers; sometimes a zero divisor (x0) or a chain on rd.
            op, d = r.choice(M_OPS), self.rd()
            t = r.random()
            if t < 0.15:
                return [f"{op} {d}, {self.rs()}, x0"]
            if t < 0.3 and d != "x0":
                return [f"{op} {d}, {self.rs()}, {self.rs()}", f"{r.choice(M_OPS)} {self.rd()}, {d}, {d}"]
            return [f"{op} {d}, {self.rs()}, {self.rs()}"]
        if kind == "imm":
            if r.random() < 0.3:
                return [f"{r.choice(SH_OPS)} {self.rd()}, {self.rs()}, "
                        f"{r.choice([0, 1, 31, r.randint(0, 31)])}"]
            return [f"{r.choice(I_OPS)} {self.rd()}, {self.rs()}, {self.imm12()}"]
        if kind == "upper":
            return [f"{r.choice(['lui', 'auipc'])} {self.rd()}, {r.randint(0, 0xFFFFF):#x}"]
        if kind == "load":
            op = r.choice(list(LOADS))
            return [f"{op} {self.rd()}, {self.mem_off(LOADS[op], False)}(x31)"]
        if kind == "store":
            op = r.choice(list(STORES))
            return [f"{op} {self.rs()}, {self.mem_off(STORES[op], False)}(x31)"]
        if kind == "branch":
            return [f"{r.choice(BR_OPS)} {self.rs()}, {self.rs()}, {fwd()}"]
        if kind == "jal":
            return [f"jal {self.rd()}, {fwd()}"]
        if kind == "jalr":
            return [f"la x29, {fwd()}", f"jalr {self.rd()}, 0(x29)"]
        if kind == "csr":
            op = r.choice(["csrrw", "csrrs", "csrrc", "csrrwi", "csrrsi", "csrrci", "read"])
            if op == "read":
                return [f"csrr {self.rd()}, {r.choice(['misa', 'mhartid', 'mstatus', 'mscratch', 'minstret', 'mtval', 'mcause', 'mepc'])}"]
            src = self.rs() if not op.endswith("i") else r.randint(0, 31)
            return [f"{op} {self.rd()}, mscratch, {src}"]
        if kind == "misc":
            return [r.choice(["nop", "fence", "fence rw, rw", "wfi"])]
        if kind == "trap":
            t = r.choice(["ecall", "ebreak", "illegal", "lmis", "smis", "jmis", "bmis"])
            if t in ("ecall", "ebreak"):
                return [t]
            if t == "illegal":
                return [f".word {r.choice([0, 0xFFFFFFFF, 0x0000100F, 0x04000033, 0x00003003]):#010x}"]
            if t == "lmis":
                op = r.choice(["lh", "lhu", "lw"])
                return [f"{op} {self.rd()}, {self.mem_off(LOADS[op], True)}(x31)"]
            if t == "smis":
                op = r.choice(["sh", "sw"])
                return [f"{op} {self.rs()}, {self.mem_off(STORES[op], True)}(x31)"]
            if t == "jmis":
                return [f"la x29, {fwd()}", f"jalr {self.rd()}, 2(x29)"]
            return [f"{r.choice(BR_OPS)} {self.rs()}, {self.rs()}, {fwd()} + 2"]
        raise ValueError(kind)

    def gen_block(self, n):
        b = self.nblk
        self.nblk += 1
        kinds, weights = zip(*[(k, w) for k, w in self.mix.items() if w > 0])
        lbl = lambda j: f"b{b}_{j}"  # noqa: E731
        out = []
        for idx in range(n):
            out.append(f"{lbl(idx)}:")
            kind = self.rng.choices(kinds, weights)[0]
            out += ["    " + s for s in self.item(kind, idx, n, lbl)]
        out.append(f"{lbl(n)}:")
        if self.rng.random() < self.loop_prob:
            out = ([f"    li x30, {self.rng.randint(1, 4)}", f"loop{b}:"] + out
                   + ["    addi x30, x30, -1", f"    bnez x30, loop{b}"])
        return out

    def program(self):
        r = self.rng
        lines = [f"// randgen seed={self.seed} length={self.length} mix={self.mix}",
                 '    .section .text.init, "ax"', "    .globl _start", "_start:",
                 "    la x29, trap_handler", "    csrw mtvec, x29",
                 f"    li x31, {DATA_BASE + 0x800:#x}"]
        for k in range(1, 29):
            v = r.choice(INTERESTING + [r.getrandbits(32)] * 3) & 0xFFFFFFFF
            lines.append(f"    li x{k}, {v:#x}")
        left = self.length
        while left > 0:
            n = min(left, r.randint(1, self.block))
            lines += self.gen_block(n)
            left -= n
        lines += [f"    li x29, {SIG_BASE:#x}"]
        lines += [f"    sw x{k}, {4 * (k - 1)}(x29)" for k in range(1, 29)]
        lines += [f"    li x29, {SIMCTRL_EXIT:#x}", "    sw x0, 0(x29)", "1:  j 1b",
                  "    .balign 4", "trap_handler:", "    csrr x29, mepc", "    addi x29, x29, 4",
                  "    csrw mepc, x29", "    mret", ""]
        return "\n".join(lines)


def parse_mix(text):
    mix = {}
    for kv in filter(None, (text or "").split(",")):
        k, v = kv.split("=")
        if k not in DEFAULT_MIX:
            raise SystemExit(f"unknown mix key {k}; choose from {', '.join(DEFAULT_MIX)}")
        mix[k] = int(v)
    return mix


def build_and_run(seed, args, root):
    """Generate, assemble with sw/Makefile `asm`, run on the ISS. Returns (ok, message)."""
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from rv32_iss import Iss, IssError
    name = f"rand_{seed}"
    out_dir = os.path.join(args.build_dir, name)
    os.makedirs(out_dir, exist_ok=True)
    src = os.path.join(out_dir, name + ".S")
    with open(src, "w") as f:
        f.write(Gen(seed, parse_mix(args.mix), args.length).program())
    p = subprocess.run(["make", "-s", "-C", os.path.join(root, "sw"), "asm", f"SRC={src}",
                        f"NAME={name}", f"BUILD={os.path.abspath(args.build_dir)}"],
                       capture_output=True, text=True)
    if p.returncode:
        return False, f"{name}: build failed\n{p.stdout}{p.stderr}"
    iss = Iss()
    iss.load(os.path.join(out_dir, name + ".hex"))
    try:
        code = iss.run(args.max_steps)
    except IssError as e:
        return False, f"{name}: {e}"
    return code == 0, f"{name}: exit {code} after {iss.order} records"


def main(argv=None):
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--length", type=int, default=400, help="body items (max 3000)")
    ap.add_argument("--mix", default="", help="e.g. alu=30,load=10,trap=0")
    ap.add_argument("-o", "--output", help="write assembly here (default stdout)")
    ap.add_argument("--batch", type=int, help="generate/build/run this many seeds from --seed")
    ap.add_argument("--build-dir", default=os.path.join(root, "build", "sw"))
    ap.add_argument("--max-steps", type=int, default=200_000)
    args = ap.parse_args(argv)
    if not 1 <= args.length <= 3000:
        ap.error("--length must be 1..3000 (code must stay below DATA_BASE)")
    if args.batch:
        fails = 0
        for s in range(args.seed, args.seed + args.batch):
            ok, msg = build_and_run(s, args, root)
            fails += not ok
            print(("PASS " if ok else "FAIL ") + msg)
        print(f"randgen: {args.batch - fails}/{args.batch} programs ran to EXIT 0 on the ISS")
        return 1 if fails else 0
    text = Gen(args.seed, parse_mix(args.mix), args.length).program()
    if args.output:
        with open(args.output, "w") as f:
            f.write(text)
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
