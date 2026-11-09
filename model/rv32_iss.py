#!/usr/bin/env python3
"""RV32I + Zicsr machine-mode ISS for p2-riscv-soc (docs/spec.md sections 2, 3, 5, 8).

Golden model for the RTL lockstep bench. One step() = one RVFI record.

Record conventions (the RTL trace must match these):
- rd_addr/rd_wdata are 0 when nothing is written (rd = x0, branches, stores, traps).
- rs1/rs2 are reported only for formats that read them (R, I, S, B, CSR reg forms);
  otherwise addr and rdata are 0. A trapping instruction still reports the rs it read;
  an illegal instruction reports none.
- Memory fields: mem_addr is the word-aligned address, masks are byte lanes within that
  word, mem_rdata/mem_wdata hold the lane bytes only (other lanes 0). All 0 on a trap.
- pc_wdata is the next pc: mtvec for a trapping instruction, mepc for MRET.
- intr = 1 on the first instruction of a handler, entered by an interrupt or a trap.
- A trapping instruction does not increment minstret. A CSR write to mcycle(h)/minstret(h)
  replaces that step's increment.

Timing model: each step advances mcycle and TIMER mtime by `cycles` (default
cycles_per_step = 1, i.e. one per retired record). Reads of mcycle/cycle/mip and TIMER
MTIME are flagged `nondet` since they depend on RTL timing.

Interrupts: with auto_irq=True (standalone runs) MTIP = mtime >= mtimecmp and MEIP =
set_external_irq() level, taken between steps when enabled. With auto_irq=False
(lockstep) only raise_interrupt(kind) takes one, before the next step.
"""
import argparse
import struct
import sys
from dataclasses import dataclass

M32 = 0xFFFFFFFF
M64 = (1 << 64) - 1
RAM_SIZE = 0x10000
RAM_WORDS = RAM_SIZE // 4
MISA = 0x40000100  # MXL=1 (32-bit), I

UART_BASE, GPIO_BASE, TIMER_BASE, SIMCTRL_BASE = 0x10000000, 0x10001000, 0x10002000, 0x1000F000

CAUSE_INSN_MISALIGNED = 0
CAUSE_ILLEGAL = 2
CAUSE_BREAKPOINT = 3
CAUSE_LOAD_MISALIGNED = 4
CAUSE_STORE_MISALIGNED = 6
CAUSE_ECALL_M = 11
CAUSE_IRQ_TIMER = 0x80000007
CAUSE_IRQ_EXT = 0x8000000B

CSR = dict(mstatus=0x300, misa=0x301, mie=0x304, mtvec=0x305, mscratch=0x340, mepc=0x341,
           mcause=0x342, mtval=0x343, mip=0x344, mcycle=0xB00, minstret=0xB02,
           mcycleh=0xB80, minstreth=0xB82, cycle=0xC00, instret=0xC02, cycleh=0xC80,
           instreth=0xC82, mvendorid=0xF11, marchid=0xF12, mimpid=0xF13, mhartid=0xF14)
CSR_NONDET = {CSR[n] for n in ("mcycle", "mcycleh", "cycle", "cycleh", "mip")}


@dataclass
class Retire:
    valid: int = 1
    order: int = 0
    insn: int = 0
    trap: int = 0
    intr: int = 0
    rs1_addr: int = 0
    rs2_addr: int = 0
    rs1_rdata: int = 0
    rs2_rdata: int = 0
    rd_addr: int = 0
    rd_wdata: int = 0
    pc_rdata: int = 0
    pc_wdata: int = 0
    mem_addr: int = 0
    mem_rmask: int = 0
    mem_wmask: int = 0
    mem_rdata: int = 0
    mem_wdata: int = 0
    # Not RVFI: mcause written by this record's trap or by the interrupt taken before it.
    cause: int = None
    # Not RVFI: rd_wdata / mem_rdata depends on timing.
    nondet: bool = False


class IssError(Exception):
    pass


class Halted(IssError):
    pass


class _Trap(Exception):
    def __init__(self, cause, tval=0):
        super().__init__(cause)
        self.cause, self.tval = cause, tval & M32


def sext(v, bits):
    v &= (1 << bits) - 1
    return v - (1 << bits) if v >> (bits - 1) else v


def lanes(be):
    return sum(0xFF << (8 * i) for i in range(4) if be >> i & 1)


class Iss:
    def __init__(self, auto_irq=True, cycles_per_step=1, reset_pc=0):
        self.auto_irq = auto_irq
        self.cycles_per_step = cycles_per_step
        self.ram = bytearray(RAM_SIZE)
        self.x = [0] * 32
        self.pc = reset_pc
        self.order = 0
        # CSRs
        self.mstatus_mie = 0
        self.mstatus_mpie = 0
        self.mie = 0
        self.mtvec = 0
        self.mscratch = 0
        self.mepc = 0
        self.mcause = 0
        self.mtval = 0
        self.mcycle = 0
        self.minstret = 0
        # devices
        self.mtime = 0
        self.mtimecmp = M64
        self.ext_irq = 0
        self.uart_tx = bytearray()
        self.uart_div = 868
        self.uart_irq_en = 0
        self.gpio_out = 0
        self.gpio_in = 0
        self.console = []
        self.exit_code = None
        self._pending = None
        self._handler_entry = False
        self._cnt_written = set()
        self._nondet = False

    # ---------------------------------------------------------------- loading
    def load_hex(self, path):
        """$readmemh image: one 32-bit word per line, optional @word_address lines."""
        addr = 0
        with open(path) as f:
            for line in f:
                line = line.split("//")[0].strip()
                for tok in line.split():
                    if tok.startswith("@"):
                        addr = int(tok[1:], 16)
                        continue
                    if addr >= RAM_WORDS:
                        raise IssError(f"{path}: image larger than RAM")
                    self.ram[addr * 4:addr * 4 + 4] = (int(tok, 16) & M32).to_bytes(4, "little")
                    addr += 1

    def load_elf(self, path):
        data = open(path, "rb").read()
        if data[:4] != b"\x7fELF" or data[4] != 1 or data[5] != 1:
            raise IssError(f"{path}: not a little-endian ELF32 file")
        entry, phoff = struct.unpack_from("<II", data, 24)
        phentsize, phnum = struct.unpack_from("<HH", data, 42)
        for i in range(phnum):
            p_type, p_off, _vaddr, p_paddr, p_filesz, p_memsz, _fl, _al = struct.unpack_from(
                "<8I", data, phoff + i * phentsize)
            if p_type != 1:
                continue
            if p_paddr + p_memsz > RAM_SIZE:
                raise IssError(f"{path}: segment at {p_paddr:#x} outside RAM")
            self.ram[p_paddr:p_paddr + p_memsz] = bytes(p_memsz)
            self.ram[p_paddr:p_paddr + p_filesz] = data[p_off:p_off + p_filesz]
        self.pc = entry

    def load(self, path):
        if path.endswith(".elf"):
            self.load_elf(path)
        else:
            self.load_hex(path)

    # ---------------------------------------------------------------- state helpers
    @property
    def halted(self):
        return self.exit_code is not None

    @property
    def console_text(self):
        return "".join(self.console)

    def mstatus(self):
        return (self.mstatus_mie << 3) | (self.mstatus_mpie << 7) | (3 << 11)

    def mip(self):
        return (int(self.mtime >= self.mtimecmp) << 7) | (self.ext_irq << 11)

    def set_external_irq(self, level):
        self.ext_irq = 1 if level else 0

    def raise_interrupt(self, kind):
        """Take interrupt `kind` ('timer' or 'external') before the next step.

        Raises IssError when the ISS state does not allow it (mstatus.MIE or the mie bit
        clear): the RTL took an interrupt the architecture forbids.
        """
        bit = {"timer": 7, "external": 11}[kind]
        if not (self.mstatus_mie and self.mie >> bit & 1):
            raise IssError(f"{kind} interrupt injected while disabled "
                           f"(mstatus={self.mstatus():#x}, mie={self.mie:#x})")
        self._pending = CAUSE_IRQ_TIMER if bit == 7 else CAUSE_IRQ_EXT

    def read_word(self, addr):
        a = addr & (RAM_SIZE - 4)
        return int.from_bytes(self.ram[a:a + 4], "little")

    def write_word(self, addr, value):
        a = addr & (RAM_SIZE - 4)
        self.ram[a:a + 4] = (value & M32).to_bytes(4, "little")

    # ---------------------------------------------------------------- bus (spec 5, 8)
    def _bus_read(self, addr):
        if addr >> 28 == 0:
            return self.read_word(addr)
        if addr >> 28 != 1:
            return 0
        dev, off = (addr >> 12) & 0xF, addr & 0xFFC
        if dev == 0:
            return {0x4: 0x2, 0x8: self.uart_div, 0xC: self.uart_irq_en}.get(off, 0)
        if dev == 1:
            return {0x0: self.gpio_out, 0x4: self.gpio_in}.get(off, 0)
        if dev == 2:
            if off in (0x0, 0x4):
                self._nondet = True
            return {0x0: self.mtime & M32, 0x4: self.mtime >> 32,
                    0x8: self.mtimecmp & M32, 0xC: self.mtimecmp >> 32}.get(off, 0)
        return 0

    def _bus_write(self, addr, data, be):
        m = lanes(be)
        if addr >> 28 == 0:
            a = addr & (RAM_SIZE - 4)
            for i in range(4):
                if be >> i & 1:
                    self.ram[a + i] = data >> (8 * i) & 0xFF
            return
        if addr >> 28 != 1:
            return
        dev, off = (addr >> 12) & 0xF, addr & 0xFFC

        def merge(old):
            return (old & ~m | data & m) & M32
        # Writes act on the enabled byte lanes only (APB4 pstrb = be, spec 5 and 8).
        if dev == 0:
            if off == 0x0:
                if be & 1:
                    self.uart_tx.append(data & 0xFF)
            elif off == 0x8:
                self.uart_div = merge(self.uart_div) & 0xFFFF
            elif off == 0xC:
                self.uart_irq_en = merge(self.uart_irq_en) & 1
        elif dev == 1:
            v = data & m & 0xFFFF
            if off == 0x0:
                self.gpio_out = merge(self.gpio_out) & 0xFFFF
            elif off == 0x8:
                self.gpio_out |= v
            elif off == 0xC:
                self.gpio_out &= ~v & 0xFFFF
        elif dev == 2:
            lo, hi = self.mtime & M32, self.mtime >> 32
            clo, chi = self.mtimecmp & M32, self.mtimecmp >> 32
            if off == 0x0:
                self.mtime = hi << 32 | merge(lo)
            elif off == 0x4:
                self.mtime = merge(hi) << 32 | lo
            elif off == 0x8:
                self.mtimecmp = chi << 32 | merge(clo)
            elif off == 0xC:
                self.mtimecmp = merge(chi) << 32 | clo
        elif dev == 0xF:
            if off == 0x0:
                self.exit_code = data & m
            elif off == 0x4 and be & 1:
                self.console.append(chr(data & 0xFF))

    # ---------------------------------------------------------------- CSRs
    def _csr_read(self, a):
        if a in CSR_NONDET:
            self._nondet = True
        if a == 0x300:
            return self.mstatus()
        if a == 0x301:
            return MISA
        if a == 0x304:
            return self.mie
        if a == 0x305:
            return self.mtvec
        if a == 0x340:
            return self.mscratch
        if a == 0x341:
            return self.mepc
        if a == 0x342:
            return self.mcause
        if a == 0x343:
            return self.mtval
        if a == 0x344:
            return self.mip()
        if a in (0xB00, 0xC00):
            return self.mcycle & M32
        if a in (0xB80, 0xC80):
            return self.mcycle >> 32
        if a in (0xB02, 0xC02):
            return self.minstret & M32
        if a in (0xB82, 0xC82):
            return self.minstret >> 32
        if a in (0xF11, 0xF12, 0xF13, 0xF14):
            return 0
        raise _Trap(CAUSE_ILLEGAL)

    def _csr_write(self, a, v):
        if a == 0x300:
            self.mstatus_mie, self.mstatus_mpie = v >> 3 & 1, v >> 7 & 1
        elif a == 0x304:
            self.mie = v & 0x880
        elif a == 0x305:
            self.mtvec = v & ~3 & M32
        elif a == 0x340:
            self.mscratch = v
        elif a == 0x341:
            self.mepc = v & ~3 & M32
        elif a == 0x342:
            self.mcause = v
        elif a == 0x343:
            self.mtval = v
        elif a == 0xB00:
            self.mcycle = (self.mcycle & ~M32 & M64) | v
            self._cnt_written.add("mcycle")
        elif a == 0xB80:
            self.mcycle = (v << 32) | (self.mcycle & M32)
            self._cnt_written.add("mcycle")
        elif a == 0xB02:
            self.minstret = (self.minstret & ~M32 & M64) | v
            self._cnt_written.add("minstret")
        elif a == 0xB82:
            self.minstret = (v << 32) | (self.minstret & M32)
            self._cnt_written.add("minstret")
        # misa and mip: writes ignored (WARL / read-only bits in a read-write address)

    # ---------------------------------------------------------------- execution
    def step(self, cycles=None):
        if self.halted:
            raise Halted(f"program exited with code {self.exit_code}")
        cyc = self.cycles_per_step if cycles is None else cycles
        r = Retire(order=self.order, intr=int(self._handler_entry))
        self._handler_entry = False
        self._cnt_written = set()
        self._nondet = False

        cause = self._pending
        self._pending = None
        if cause is None and self.auto_irq and self.mstatus_mie:
            p = self.mip() & self.mie
            cause = CAUSE_IRQ_EXT if p & 0x800 else CAUSE_IRQ_TIMER if p & 0x80 else None
        if cause is not None:
            self._enter_trap(cause, 0, self.pc)
            self.pc = self.mtvec
            r.intr, r.cause = 1, cause

        pc = self.pc
        r.pc_rdata = pc
        r.insn = self.read_word(pc)
        try:
            npc = self._exec(r.insn, r)
        except _Trap as t:
            r.trap, r.cause = 1, t.cause
            r.rd_addr = r.rd_wdata = 0
            if t.cause == CAUSE_ILLEGAL:
                r.rs1_addr = r.rs1_rdata = r.rs2_addr = r.rs2_rdata = 0
            r.mem_addr = r.mem_rmask = r.mem_wmask = r.mem_rdata = r.mem_wdata = 0
            self._enter_trap(t.cause, t.tval, pc)
            self._handler_entry = True
            npc = self.mtvec
        r.pc_wdata = npc
        r.nondet = self._nondet
        self.pc = npc
        if "mcycle" not in self._cnt_written:
            self.mcycle = (self.mcycle + cyc) & M64
        if "minstret" not in self._cnt_written and not r.trap:
            self.minstret = (self.minstret + 1) & M64
        self.mtime = (self.mtime + cyc) & M64
        self.order += 1
        return r

    def _enter_trap(self, cause, tval, epc):
        self.mepc = epc & ~3 & M32
        self.mcause = cause
        self.mtval = tval
        self.mstatus_mpie = self.mstatus_mie
        self.mstatus_mie = 0

    def run(self, max_steps=10_000_000, trace=None):
        n = 0
        while not self.halted:
            if n >= max_steps:
                raise IssError(f"no EXIT after {max_steps} steps (pc={self.pc:#010x})")
            r = self.step()
            if trace:
                trace(r)
            n += 1
        return self.exit_code

    def _exec(self, insn, r):
        x = self.x
        pc = r.pc_rdata
        op = insn & 0x7F
        rd = insn >> 7 & 31
        f3 = insn >> 12 & 7
        rs1 = insn >> 15 & 31
        rs2 = insn >> 20 & 31
        f7 = insn >> 25
        imm_i = sext(insn >> 20, 12)
        npc = (pc + 4) & M32
        illegal = _Trap(CAUSE_ILLEGAL, insn)

        def src1():
            r.rs1_addr, r.rs1_rdata = rs1, x[rs1]
            return x[rs1]

        def src2():
            r.rs2_addr, r.rs2_rdata = rs2, x[rs2]
            return x[rs2]

        def jump(target):
            target &= M32
            if target & 3:
                raise _Trap(CAUSE_INSN_MISALIGNED, target)
            return target

        res = None  # value for rd
        if op == 0x37:  # LUI
            res = insn & 0xFFFFF000
        elif op == 0x17:  # AUIPC
            res = (pc + (insn & 0xFFFFF000)) & M32
        elif op == 0x6F:  # JAL
            imm = sext(((insn >> 31) << 20) | ((insn >> 12 & 0xFF) << 12)
                       | ((insn >> 20 & 1) << 11) | ((insn >> 21 & 0x3FF) << 1), 21)
            npc = jump(pc + imm)
            res = (pc + 4) & M32
        elif op == 0x67:  # JALR
            if f3 != 0:
                raise illegal
            npc = jump((src1() + imm_i) & ~1)
            res = (pc + 4) & M32
        elif op == 0x63:  # branches
            if f3 in (2, 3):
                raise illegal
            a, b = src1(), src2()
            sa, sb = sext(a, 32), sext(b, 32)
            taken = {0: a == b, 1: a != b, 4: sa < sb, 5: sa >= sb, 6: a < b, 7: a >= b}[f3]
            if taken:
                imm = sext(((insn >> 31) << 12) | ((insn >> 7 & 1) << 11)
                           | ((insn >> 25 & 0x3F) << 5) | ((insn >> 8 & 0xF) << 1), 13)
                npc = jump(pc + imm)
        elif op == 0x03:  # loads
            if f3 not in (0, 1, 2, 4, 5):
                raise illegal
            addr = (src1() + imm_i) & M32
            size = 1 << (f3 & 3)
            if addr & (size - 1):
                raise _Trap(CAUSE_LOAD_MISALIGNED, addr)
            sh = 8 * (addr & 3)
            be = ((1 << size) - 1) << (addr & 3)
            word = self._bus_read(addr & ~3) & lanes(be)
            v = word >> sh
            res = {0: sext(v, 8) & M32, 1: sext(v, 16) & M32, 2: v, 4: v & 0xFF, 5: v & 0xFFFF}[f3]
            r.mem_addr, r.mem_rmask, r.mem_rdata = addr & ~3, be, word
        elif op == 0x23:  # stores
            if f3 > 2:
                raise illegal
            imm = sext(((insn >> 25) << 5) | rd, 12)
            addr = (src1() + imm) & M32
            data = src2()
            size = 1 << f3
            if addr & (size - 1):
                raise _Trap(CAUSE_STORE_MISALIGNED, addr)
            be = ((1 << size) - 1) << (addr & 3)
            wdata = (data << (8 * (addr & 3))) & lanes(be)
            r.mem_addr, r.mem_wmask, r.mem_wdata = addr & ~3, be, wdata
            self._bus_write(addr & ~3, wdata, be)
            rd = 0
        elif op == 0x13:  # OP-IMM
            a = src1()
            sh = imm_i & 31
            if f3 == 1:
                if f7 != 0:
                    raise illegal
                res = (a << sh) & M32
            elif f3 == 5:
                if f7 == 0:
                    res = a >> sh
                elif f7 == 0x20:
                    res = (sext(a, 32) >> sh) & M32
                else:
                    raise illegal
            else:
                res = self._alu(f3, a, imm_i & M32)
        elif op == 0x33:  # OP
            a, b = src1(), src2()
            if f7 == 0x20 and f3 in (0, 5):
                res = (a - b) & M32 if f3 == 0 else (sext(a, 32) >> (b & 31)) & M32
            elif f7 == 0:
                if f3 == 1:
                    res = (a << (b & 31)) & M32
                elif f3 == 5:
                    res = a >> (b & 31)
                else:
                    res = self._alu(f3, a, b)
            else:
                raise illegal
        elif op == 0x0F:  # FENCE (no-op); FENCE.I is not implemented
            if f3 != 0:
                raise illegal
        elif op == 0x73:  # SYSTEM
            if f3 == 0:
                if insn == 0x00000073:
                    raise _Trap(CAUSE_ECALL_M, 0)
                if insn == 0x00100073:
                    raise _Trap(CAUSE_BREAKPOINT, 0)
                if insn == 0x30200073:  # MRET
                    npc = self.mepc
                    self.mstatus_mie, self.mstatus_mpie = self.mstatus_mpie, 1
                elif insn == 0x10500073:  # WFI
                    pass
                else:
                    raise illegal
            elif f3 == 4:
                raise illegal
            else:
                a = insn >> 20
                src = src1() if f3 < 4 else rs1
                writes = f3 in (1, 5) or rs1 != 0
                if writes and a >> 10 == 3:
                    raise illegal
                try:
                    old = self._csr_read(a)
                except _Trap:
                    raise illegal from None
                if writes:
                    kind = f3 & 3
                    new = src if kind == 1 else old | src if kind == 2 else old & ~src & M32
                    self._csr_write(a, new)
                res = old
        else:
            raise illegal

        if res is not None and rd != 0:
            x[rd] = res & M32
            r.rd_addr, r.rd_wdata = rd, x[rd]
        return npc

    @staticmethod
    def _alu(f3, a, b):
        if f3 == 0:
            return (a + b) & M32
        if f3 == 2:
            return int(sext(a, 32) < sext(b, 32))
        if f3 == 3:
            return int(a < b)
        if f3 == 4:
            return a ^ b
        if f3 == 6:
            return a | b
        return a & b  # f3 == 7


def format_record(r):
    s = (f"{r.order:6d} pc={r.pc_rdata:08x} insn={r.insn:08x} -> {r.pc_wdata:08x}"
         f"{' TRAP' if r.trap else ''}{' INTR' if r.intr else ''}")
    if r.rd_addr:
        s += f" x{r.rd_addr}={r.rd_wdata:08x}"
    if r.mem_rmask:
        s += f" ld[{r.mem_addr:08x}/{r.mem_rmask:x}]={r.mem_rdata:08x}"
    if r.mem_wmask:
        s += f" st[{r.mem_addr:08x}/{r.mem_wmask:x}]={r.mem_wdata:08x}"
    if r.cause is not None:
        s += f" mcause={r.cause:08x}"
    return s


def main(argv=None):
    ap = argparse.ArgumentParser(description="Run a program on the RV32I ISS.")
    ap.add_argument("program", help=".hex ($readmemh words) or .elf")
    ap.add_argument("--max-steps", type=int, default=10_000_000)
    ap.add_argument("--cycles-per-step", type=int, default=1,
                    help="mtime/mcycle advance per retired record (default 1)")
    ap.add_argument("--trace", action="store_true", help="print one line per record")
    args = ap.parse_args(argv)
    iss = Iss(cycles_per_step=args.cycles_per_step)
    iss.load(args.program)
    tr = (lambda r: print(format_record(r))) if args.trace else None
    try:
        code = iss.run(args.max_steps, trace=tr)
    except IssError as e:
        print(f"error: {e}", file=sys.stderr)
        return 2
    if iss.console:
        print("[simctrl] " + iss.console_text, end="" if iss.console_text.endswith("\n") else "\n")
    if iss.uart_tx:
        t = iss.uart_tx.decode("latin-1")
        print("[uart] " + t, end="" if t.endswith("\n") else "\n")
    print(f"exit code {code} ({code:#x}) after {iss.order} instructions")
    return 0 if code == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
