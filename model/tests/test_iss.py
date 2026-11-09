"""Unit tests for model/rv32_iss.py against docs/spec.md sections 2, 3, 5, 8."""
import pytest

import enc as E
from rv32_iss import (CAUSE_IRQ_EXT, CAUSE_IRQ_TIMER, M32, Halted, Iss, IssError, MISA,
                      format_record)

MTVEC = 0x400
RAM_DATA = 0x8000


def mk(words, regs=None, auto_irq=True, mtvec=MTVEC):
    iss = Iss(auto_irq=auto_irq)
    flat = []
    for w in words:
        flat.extend(w if isinstance(w, list) else [w])
    for n, w in enumerate(flat):
        iss.write_word(4 * n, w)
    for k, v in (regs or {}).items():
        iss.x[k] = v & M32
    iss.mtvec = mtvec
    return iss


def run1(insn, regs=None):
    iss = mk([insn], regs)
    return iss, iss.step()


# --------------------------------------------------------------------------- ALU
R_CASES = [
    ("add", 1, 1, 2), ("add", 0x7FFFFFFF, 1, 0x80000000), ("add", M32, 1, 0),
    ("add", M32, M32, 0xFFFFFFFE), ("sub", 0, 1, M32), ("sub", 0x80000000, 1, 0x7FFFFFFF),
    ("sub", 3, 7, 0xFFFFFFFC), ("sll", 1, 31, 0x80000000), ("sll", 1, 32, 1),
    ("sll", 1, 0xFFFFFFE1, 2), ("sll", 0x21212121, 14, 0x48484000),
    ("slt", M32, 0, 1), ("slt", 0, M32, 0), ("slt", 0x80000000, 0x7FFFFFFF, 1),
    ("slt", 5, 5, 0), ("sltu", M32, 0, 0), ("sltu", 0, M32, 1),
    ("sltu", 0x7FFFFFFF, 0x80000000, 1), ("xor", 0xFF00FF00, 0x0F0F0F0F, 0xF00FF00F),
    ("srl", 0x80000000, 31, 1), ("srl", 0x80000000, 0xFFFFFFE1, 0x40000000),
    ("srl", M32, 0, M32), ("sra", 0x80000000, 1, 0xC0000000), ("sra", 0x80000000, 31, M32),
    ("sra", 0x7FFFFFFF, 31, 0), ("sra", 0x81818181, 7, 0xFF030303),
    ("sra", 0x81818181, 0xFFFFFFC0, 0x81818181), ("or", 0xFF00FF00, 0x0F0F0F0F, 0xFF0FFF0F),
    ("and", 0xFF00FF00, 0x0F0F0F0F, 0x0F000F00),
]


@pytest.mark.parametrize("op,a,b_,exp", R_CASES)
def test_r_type(op, a, b_, exp):
    _, rec = run1(E.r(op, 3, 1, 2), {1: a, 2: b_})
    assert (rec.rd_addr, rec.rd_wdata) == (3, exp)
    assert (rec.rs1_addr, rec.rs1_rdata, rec.rs2_addr, rec.rs2_rdata) == (1, a, 2, b_)
    assert rec.pc_wdata == 4 and not rec.trap


I_CASES = [
    ("addi", 0, -2048, 0xFFFFF800), ("addi", 0, 2047, 0x7FF), ("addi", 0x7FFFFFFF, 1, 0x80000000),
    ("addi", M32, 1, 0), ("slti", M32, 0, 1), ("slti", 0, -1, 0), ("slti", 0xFFFFF7FF, -2048, 1),
    ("sltiu", 0, -1, 1), ("sltiu", M32, -1, 0), ("sltiu", 0x7FFFFFFF, -2048, 1),
    ("sltiu", 0, 1, 1), ("xori", 0x00FF0F00, -1, 0xFF00F0FF),
    ("xori", 0x00FF0F00, -2033, 0xFF00F70F), ("ori", 0xFF00FF00, -241, 0xFFFFFF0F),
    ("andi", 0xFF00FF00, -241, 0xFF00FF00), ("andi", 0x00FF00FF, 0x70F, 0xF),
    ("slli", 1, 31, 0x80000000), ("slli", M32, 14, 0xFFFFC000), ("srli", 0x80000000, 31, 1),
    ("srli", M32, 0, M32), ("srai", 0x80000000, 31, M32), ("srai", 0x80000000, 0, 0x80000000),
    ("srai", 0x81818181, 7, 0xFF030303), ("srai", 0x7FFFFFFF, 31, 0),
]


@pytest.mark.parametrize("op,a,imm,exp", I_CASES)
def test_i_type(op, a, imm, exp):
    _, rec = run1(E.i(op, 3, 1, imm), {1: a})
    assert (rec.rd_addr, rec.rd_wdata) == (3, exp)
    assert (rec.rs1_addr, rec.rs2_addr, rec.rs2_rdata) == (1, 0, 0)


def test_lui_auipc():
    iss = mk([E.lui(1, 0xFFFFF), E.auipc(2, 0), E.auipc(3, 1), E.auipc(4, 0xFFFFF)])
    recs = [iss.step() for _ in range(4)]
    assert recs[0].rd_wdata == 0xFFFFF000
    assert recs[1].rd_wdata == 4
    assert recs[2].rd_wdata == 0x1008
    assert recs[3].rd_wdata == (12 - 0x1000) & M32
    assert all(r.rs1_addr == 0 and r.rs2_addr == 0 for r in recs)


@pytest.mark.parametrize("insn", [
    E.r("add", 0, 1, 2), E.i("addi", 0, 1, 5), E.lui(0, 1), E.auipc(0, 1), E.jal(0, 8),
    E.load("lw", 0, 0, 0x100), E.csr("csrrs", 0, 0x340, 0)])
def test_x0_writes_discarded(insn):
    iss, rec = run1(insn, {1: 7, 2: 9})
    assert iss.x[0] == 0
    assert rec.rd_addr == 0 and rec.rd_wdata == 0


def test_x0_reads_zero_and_rs_fields():
    _, rec = run1(E.r("add", 3, 0, 0))
    assert (rec.rs1_addr, rec.rs1_rdata, rec.rd_wdata) == (0, 0, 0)


# --------------------------------------------------------------------------- control flow
BR = [("beq", 1, 1, True), ("beq", 1, 2, False), ("bne", 1, 2, True), ("bne", 3, 3, False),
      ("blt", M32, 1, True), ("blt", 1, M32, False), ("blt", 5, 5, False),
      ("bge", 1, M32, True), ("bge", 5, 5, True), ("bge", 0x80000000, 0x7FFFFFFF, False),
      ("bltu", 1, M32, True), ("bltu", M32, 1, False), ("bgeu", M32, 1, True),
      ("bgeu", 0, M32, False), ("bgeu", 7, 7, True)]


@pytest.mark.parametrize("op,a,b_,taken", BR)
def test_branches(op, a, b_, taken):
    iss = mk([E.NOP, E.b(op, 1, 2, -4)], {1: a, 2: b_})
    iss.pc = 4
    rec = iss.step()
    assert rec.pc_wdata == (0 if taken else 8)
    assert rec.rd_addr == 0 and (rec.rs1_addr, rec.rs2_addr) == (1, 2)


def test_branch_misaligned_target_traps_only_when_taken():
    iss = mk([E.b("beq", 0, 0, 6)])
    rec = iss.step()
    assert rec.trap and rec.cause == 0 and rec.pc_wdata == MTVEC
    assert iss.mtval == 6 and iss.mepc == 0
    iss = mk([E.b("bne", 0, 0, 6)])
    rec = iss.step()
    assert not rec.trap and rec.pc_wdata == 4


def test_jal_link_and_target():
    iss = mk([E.NOP, E.jal(1, 0x100)])
    iss.pc = 4
    rec = iss.step()
    assert (rec.rd_addr, rec.rd_wdata, rec.pc_wdata) == (1, 8, 0x104)
    iss = mk([E.NOP, E.NOP, E.jal(1, -8)])
    iss.pc = 8
    assert iss.step().pc_wdata == 0


def test_jalr_clears_bit0_and_rd_eq_rs1():
    _, rec = run1(E.jalr(1, 1, 1), {1: 0x200})
    assert (rec.pc_wdata, rec.rd_wdata, rec.rs1_rdata) == (0x200, 4, 0x200)
    _, rec = run1(E.jalr(2, 1, -16), {1: 0x210})
    assert rec.pc_wdata == 0x200


@pytest.mark.parametrize("insn,regs,target", [
    (E.jal(1, 2), {}, 2), (E.jalr(1, 2, 2), {2: 0x100}, 0x102),
    (E.jalr(1, 2, 3), {2: 0x100}, 0x102)])
def test_jump_misaligned(insn, regs, target):
    iss, rec = run1(insn, {**regs, 1: 0x99})
    assert rec.trap and rec.cause == 0 and iss.mtval == target
    assert rec.rd_addr == 0 and iss.x[1] == 0x99 and rec.pc_wdata == MTVEC


# --------------------------------------------------------------------------- memory
LOADS = [("lb", 0, 0xFFFFFF80), ("lb", 1, 0x7F), ("lb", 3, 0xFFFFFFFF), ("lbu", 0, 0x80),
         ("lbu", 3, 0xFF), ("lh", 0, 0x7F80), ("lh", 2, 0xFFFFFF01), ("lhu", 2, 0xFF01),
         ("lw", 0, 0xFF017F80)]


@pytest.mark.parametrize("op,off,exp", LOADS)
def test_loads(op, off, exp):
    iss = mk([E.load(op, 3, 1, off)], {1: RAM_DATA})
    iss.write_word(RAM_DATA, 0xFF017F80)
    rec = iss.step()
    size = {"lb": 1, "lbu": 1, "lh": 2, "lhu": 2, "lw": 4}[op]
    mask = ((1 << size) - 1) << off
    assert (rec.rd_addr, rec.rd_wdata) == (3, exp)
    assert (rec.mem_addr, rec.mem_rmask, rec.mem_wmask) == (RAM_DATA, mask, 0)
    lanes = sum(0xFF << 8 * k for k in range(4) if mask >> k & 1)
    assert rec.mem_rdata == 0xFF017F80 & lanes


def test_load_negative_offset():
    iss = mk([E.load("lw", 3, 1, -4)], {1: RAM_DATA + 4})
    iss.write_word(RAM_DATA, 0xCAFE)
    assert iss.step().rd_wdata == 0xCAFE


@pytest.mark.parametrize("op,off", [("lh", 1), ("lh", 3), ("lhu", 1), ("lw", 1), ("lw", 2),
                                    ("lw", 3)])
def test_load_misaligned(op, off):
    iss = mk([E.load(op, 3, 1, off)], {1: RAM_DATA, 3: 0x55})
    rec = iss.step()
    assert rec.trap and rec.cause == 4 and iss.mtval == RAM_DATA + off
    assert iss.x[3] == 0x55 and rec.rd_addr == 0 and rec.mem_rmask == 0
    assert rec.rs1_addr == 1   # a trapping instruction still reports what it read


STORES = [("sb", 0, 0x11223344, 0xDEADBE44, 1), ("sb", 3, 0x11223344, 0x44ADBEEF, 8),
          ("sh", 0, 0x11223344, 0xDEAD3344, 3), ("sh", 2, 0x11223344, 0x3344BEEF, 0xC),
          ("sw", 0, 0x11223344, 0x11223344, 0xF)]


@pytest.mark.parametrize("op,off,val,exp,mask", STORES)
def test_stores(op, off, val, exp, mask):
    iss = mk([E.store(op, 2, 1, off)], {1: RAM_DATA, 2: val})
    iss.write_word(RAM_DATA, 0xDEADBEEF)
    rec = iss.step()
    assert iss.read_word(RAM_DATA) == exp
    assert (rec.mem_addr, rec.mem_wmask, rec.mem_rmask, rec.rd_addr) == (RAM_DATA, mask, 0, 0)
    lanes = sum(0xFF << 8 * k for k in range(4) if mask >> k & 1)
    assert rec.mem_wdata == exp & lanes


@pytest.mark.parametrize("op,off", [("sh", 1), ("sh", 3), ("sw", 1), ("sw", 2)])
def test_store_misaligned(op, off):
    iss = mk([E.store(op, 2, 1, off)], {1: RAM_DATA, 2: 0x12345678})
    iss.write_word(RAM_DATA, 0xDEADBEEF)
    iss.write_word(RAM_DATA + 4, 0xDEADBEEF)
    rec = iss.step()
    assert rec.trap and rec.cause == 6 and iss.mtval == RAM_DATA + off
    assert iss.read_word(RAM_DATA) == 0xDEADBEEF and iss.read_word(RAM_DATA + 4) == 0xDEADBEEF
    assert rec.mem_wmask == 0 and rec.mem_wdata == 0


def test_ram_aliases_and_unmapped():
    iss = mk([E.store("sw", 2, 1, 0), E.load("lw", 3, 1, 0), E.load("lw", 4, 5, 0),
              E.store("sw", 2, 6, 0), E.load("lw", 7, 6, 0)],
             {1: 0x00010000 + RAM_DATA, 2: 0xABCD, 5: RAM_DATA, 6: 0x30000000})
    for _ in range(5):
        iss.step()
    assert iss.x[3] == 0xABCD and iss.x[4] == 0xABCD   # addr[31:28] = 0 decodes to RAM
    assert iss.x[7] == 0                                 # other regions: read 0, write dropped


# --------------------------------------------------------------------------- devices
def test_simctrl_exit_putc_and_uart_tx():
    iss = mk([*E.li(1, 0x1000F000), *E.li(5, 0x10000000), E.i("addi", 2, 0, ord("A")),
              E.store("sw", 2, 1, 4), E.store("sb", 2, 5, 0), E.i("addi", 2, 0, 7),
              E.store("sw", 2, 1, 0), E.NOP])
    assert iss.run(100) == 7
    assert iss.console_text == "A" and bytes(iss.uart_tx) == b"A"
    assert iss.halted
    with pytest.raises(Halted):
        iss.step()


def test_device_writes_act_on_enabled_lanes():
    # sb to UART DATA / SIMCTRL PUTC byte 1: no push, no print (pstrb[0] clear).
    # sb to DIVISOR byte 1 and byte 2: 16-bit register, lane 2 has no bits.
    iss = mk([*E.li(1, 0x1000F000), *E.li(5, 0x10000000), E.i("addi", 2, 0, ord("B")),
              E.store("sb", 2, 5, 1), E.store("sb", 2, 1, 5), E.store("sb", 2, 5, 9),
              E.store("sb", 2, 5, 10), E.load("lw", 3, 5, 8)])
    for _ in range(10):
        iss.step()
    assert bytes(iss.uart_tx) == b"" and iss.console_text == ""
    assert iss.x[3] == (ord("B") << 8 | 0x64)   # 868 = 0x364, byte 1 replaced


def test_uart_status_and_divisor():
    iss = mk([*E.li(1, 0x10000000), E.load("lw", 2, 1, 4), E.load("lw", 3, 1, 8),
              E.load("lw", 4, 1, 0)])
    for _ in range(5):
        iss.step()
    assert (iss.x[2], iss.x[3], iss.x[4]) == (0x2, 868, 0)   # tx_empty, reset divisor, no RX


def test_gpio_lanes_set_clr():
    iss = mk([*E.li(1, 0x10001000), *E.li(2, 0x1234ABCD), E.store("sw", 2, 1, 0),
              E.i("addi", 3, 0, 0x55), E.store("sb", 3, 1, 1), E.i("addi", 3, 0, 0x0F0),
              E.store("sw", 3, 1, 8), E.i("addi", 3, 0, 0x00D), E.store("sw", 3, 1, 12),
              E.load("lw", 4, 1, 0)])
    for _ in range(12):
        iss.step()
    assert iss.x[4] == 0x55F0


def test_timer_regs_and_cycles():
    iss = mk([*E.li(1, 0x10002000), E.load("lw", 2, 1, 0), E.load("lw", 3, 1, 8),
              E.load("lw", 4, 1, 12)])
    iss.step()
    iss.step(cycles=10)
    r = iss.step()
    assert r.nondet and iss.x[2] == 11      # mtime advanced 1 + 10 before the load
    iss.step()
    iss.step()
    assert iss.x[3] == M32 and iss.x[4] == M32
    assert iss.mcycle == 14 and iss.minstret == 5


# --------------------------------------------------------------------------- CSRs
def csr_prog(*insns, regs=None):
    iss = mk(list(insns), regs)
    return iss, [iss.step() for _ in insns]


def test_csr_all_forms():
    iss, recs = csr_prog(E.csr("csrrw", 3, 0x340, 1), E.csr("csrrs", 4, 0x340, 2),
                         E.csr("csrrc", 5, 0x340, 1), E.csr("csrrwi", 6, 0x340, 0x1F),
                         E.csr("csrrsi", 7, 0x340, 0x20 >> 1), E.csr("csrrci", 8, 0x340, 3),
                         E.csr("csrrs", 9, 0x340, 0),
                         regs={1: 0xF0F0F0F0, 2: 0x0000FFFF})
    assert [iss.x[k] for k in range(3, 10)] == [0, 0xF0F0F0F0, 0xF0F0FFFF, 0x00000F0F, 0x1F,
                                                0x1F, 0x1C]
    assert recs[0].rs1_addr == 1 and recs[3].rs1_addr == 0   # uimm forms read no register


@pytest.mark.parametrize("addr,write,exp", [
    (0x300, M32, 0x1888), (0x300, 0, 0x1800), (0x301, 0, MISA), (0x304, M32, 0x880),
    (0x305, 0x12345677, 0x12345674), (0x341, M32, 0xFFFFFFFC), (0x342, M32, M32),
    (0x343, 0x55, 0x55), (0x340, 0xABC, 0xABC), (0x344, M32, 0)])
def test_csr_warl(addr, write, exp):
    iss, _ = csr_prog(E.csr("csrrw", 0, addr, 1), E.csr("csrrs", 3, addr, 0), regs={1: write})
    assert iss.x[3] == exp


@pytest.mark.parametrize("addr", [0xF11, 0xF12, 0xF13, 0xF14])
def test_csr_id_regs(addr):
    iss, recs = csr_prog(E.csr("csrrs", 3, addr, 0), regs={3: 5})
    assert iss.x[3] == 0 and not recs[0].trap


@pytest.mark.parametrize("insn", [
    E.csr("csrrw", 3, 0xF14, 1), E.csr("csrrs", 3, 0xC00, 1), E.csr("csrrwi", 3, 0xC02, 0),
    E.csr("csrrci", 3, 0xF11, 1), E.csr("csrrs", 3, 0x7C0, 0), E.csr("csrrw", 3, 0x3A0, 1),
    E.csr("csrrs", 3, 0xB03, 0), E.csr("csrrs", 3, 0x306, 0)])
def test_csr_illegal(insn):
    iss, rec = run1(insn, {1: 1, 3: 0x77})
    assert rec.trap and rec.cause == 2 and iss.mtval == insn
    assert iss.x[3] == 0x77 and rec.rd_addr == 0 and rec.rs1_addr == 0


def test_counters():
    iss, recs = csr_prog(E.csr("csrrs", 1, 0xB02, 0), E.csr("csrrs", 2, 0xC02, 0),
                         E.csr("csrrw", 0, 0xB02, 5), E.csr("csrrs", 3, 0xB02, 0),
                         E.csr("csrrw", 0, 0xB82, 6), E.csr("csrrs", 4, 0xC82, 0),
                         E.csr("csrrs", 7, 0xB00, 0), regs={5: M32, 6: 2})
    assert (iss.x[1], iss.x[2]) == (0, 1)
    assert iss.x[3] == M32          # write replaced the csrrw's own increment
    assert iss.x[4] == 2            # minstreth written to 2 (replaces the carry step)
    assert recs[6].nondet and not recs[3].nondet
    assert iss.x[7] == 6            # mcycle: one per step by default


def test_mcycle_write_and_cycle_shadow():
    iss, _ = csr_prog(E.csr("csrrw", 0, 0xB00, 1), E.csr("csrrs", 2, 0xC00, 0),
                      E.csr("csrrw", 0, 0xB80, 1), E.csr("csrrs", 3, 0xC80, 0), regs={1: 100})
    assert iss.x[2] == 100 and iss.x[3] == 100


# --------------------------------------------------------------------------- traps
ILLEGAL = [0x00000000, 0xFFFFFFFF, 0x0000007F, 0x0000100F, 0x02109093, 0x40001093, 0x022081B3,
           0x00003003, 0x00006003, 0x00003023, 0x00002063, 0x00003063, 0x00001067, 0x00200073,
           0x00004073, 0x30200074, 0x10200073, 0x7FF00073,
           0x40007033, 0x40001033, 0x00009013 | (0x10 << 25)]


@pytest.mark.parametrize("insn", ILLEGAL)
def test_illegal(insn):
    iss, rec = run1(insn, {1: 3, 2: 4})
    assert rec.trap and rec.cause == 2 and iss.mtval == insn
    assert (rec.rd_addr, rec.rs1_addr, rec.rs2_addr) == (0, 0, 0)
    assert iss.mepc == 0 and iss.pc == MTVEC and iss.minstret == 0


@pytest.mark.parametrize("insn,cause", [(E.ECALL, 11), (E.EBREAK, 3)])
def test_ecall_ebreak(insn, cause):
    iss = mk([E.NOP, insn])
    iss.write_word(MTVEC, E.NOP)
    iss.mtval = 0x1234
    iss.mstatus_mie = 1
    iss.step()
    rec = iss.step()
    assert rec.trap and rec.cause == cause and rec.pc_rdata == 4 and rec.pc_wdata == MTVEC
    assert (iss.mepc, iss.mcause, iss.mtval) == (4, cause, 0)
    assert (iss.mstatus_mie, iss.mstatus_mpie) == (0, 1)
    assert iss.minstret == 1                       # the trapping instruction did not retire
    nxt = iss.step()
    assert nxt.intr and nxt.pc_rdata == MTVEC and not nxt.trap
    assert not iss.step().intr


def test_mret():
    iss = mk([E.MRET])
    iss.mepc, iss.mstatus_mpie, iss.mstatus_mie = 0x200, 0, 1
    rec = iss.step()
    assert rec.pc_wdata == 0x200 and (iss.mstatus_mie, iss.mstatus_mpie) == (0, 1)
    iss = mk([E.MRET])
    iss.mepc, iss.mstatus_mpie = 0x204, 1
    iss.step()
    assert iss.mstatus_mie == 1 and iss.pc == 0x204


def test_trap_roundtrip_mret_resumes():
    handler = [E.csr("csrrs", 5, 0x341, 0), E.i("addi", 5, 5, 4), E.csr("csrrw", 0, 0x341, 5),
               E.MRET]
    iss = mk([E.ECALL, E.i("addi", 1, 0, 9)])
    for n, w in enumerate(handler):
        iss.write_word(MTVEC + 4 * n, w)
    recs = [iss.step() for _ in range(6)]
    assert [r.pc_rdata for r in recs] == [0, MTVEC, MTVEC + 4, MTVEC + 8, MTVEC + 12, 4]
    assert recs[4].pc_wdata == 4 and iss.x[1] == 9
    assert [r.order for r in recs] == list(range(6))


def test_wfi_fence_nop():
    iss, recs = csr_prog(E.WFI, E.FENCE, 0x8330000F)
    assert [r.pc_wdata for r in recs] == [4, 8, 12] and not any(r.trap for r in recs)
    assert all(r.rd_addr == 0 for r in recs)


# --------------------------------------------------------------------------- interrupts
def irq_iss(auto=True):
    iss = mk([E.NOP] * 8, auto_irq=auto)
    for n in range(4):
        iss.write_word(MTVEC + 4 * n, E.NOP)
    return iss


def test_timer_irq_gating():
    iss = irq_iss()
    iss.mtimecmp = 0
    iss.mie = 0x80
    iss.step()
    assert not iss.step().intr                 # MIE = 0
    iss.mstatus_mie, iss.mie = 1, 0
    assert not iss.step().intr                 # MTIE = 0
    assert iss.mip() == 0x80
    iss.mie = 0x80
    rec = iss.step()
    assert rec.intr and rec.cause == CAUSE_IRQ_TIMER and rec.pc_rdata == MTVEC
    assert iss.mepc == 12 and iss.mcause == CAUSE_IRQ_TIMER and iss.mtval == 0
    assert (iss.mstatus_mie, iss.mstatus_mpie) == (0, 1)
    assert not iss.step().intr                 # MIE now 0


def test_timer_irq_fires_on_compare():
    iss = irq_iss()
    iss.mstatus_mie, iss.mie, iss.mtimecmp = 1, 0x80, 3
    recs = [iss.step() for _ in range(5)]
    assert [r.intr for r in recs] == [0, 0, 0, 1, 0]   # mtime = 3 before the 4th step


def test_external_priority_over_timer():
    iss = irq_iss()
    iss.mstatus_mie, iss.mie, iss.mtimecmp = 1, 0x880, 0
    iss.set_external_irq(1)
    rec = iss.step()
    assert rec.intr and iss.mcause == CAUSE_IRQ_EXT and iss.mip() == 0x880


def test_external_needs_meie():
    iss = irq_iss()
    iss.mstatus_mie, iss.mie = 1, 0x80
    iss.set_external_irq(1)
    assert not iss.step().intr


def test_injected_mode():
    iss = irq_iss(auto=False)
    iss.mstatus_mie, iss.mie, iss.mtimecmp = 1, 0x880, 0
    assert not iss.step().intr                 # internal sources ignored
    with pytest.raises(KeyError):
        iss.raise_interrupt("soft")
    iss.raise_interrupt("external")
    rec = iss.step()
    assert rec.intr and rec.cause == CAUSE_IRQ_EXT and iss.mepc == 4
    with pytest.raises(IssError):              # MIE cleared by entry
        iss.raise_interrupt("timer")
    iss.mstatus_mie, iss.mie = 1, 0x800
    with pytest.raises(IssError):              # MTIE clear
        iss.raise_interrupt("timer")


def test_interrupt_before_trapping_instruction():
    iss = irq_iss(auto=False)
    iss.write_word(MTVEC, E.ECALL)
    iss.mstatus_mie, iss.mie = 1, 0x80
    iss.raise_interrupt("timer")
    rec = iss.step()
    assert rec.intr and rec.trap and rec.cause == 11 and iss.mepc == MTVEC


# --------------------------------------------------------------------------- loading, CLI
def test_load_hex(tmp_path):
    p = tmp_path / "p.hex"
    p.write_text("00100093 // addi x1, x0, 1\n@4\n00200113\n")
    iss = Iss()
    iss.load(str(p))
    assert iss.read_word(0) == 0x00100093 and iss.read_word(16) == 0x00200113
    p.write_text("@4000\n00000000\n")
    with pytest.raises(IssError):
        Iss().load_hex(str(p))


def test_format_record():
    _, rec = run1(E.i("addi", 1, 0, 5))
    assert "x1=00000005" in format_record(rec)
