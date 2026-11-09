// Synchronous traps: ECALL, EBREAK, illegal instructions (bad opcodes/functs, bad or
// read-only CSRs), load/store address misaligned, instruction address misaligned
// (jal, jalr, taken branch), mcause/mepc/mtval, mstatus MIE/MPIE, MRET, minstret.
// The handler records mcause/mepc/mtval/mstatus in x25/x26/x27/x23, counts traps in
// x24 and resumes at mepc + 4.
#include "isa.h"

.macro ARM
    li    x25, -1
    li    x26, -1
    li    x27, -1
.endm

.set NTRAP, 0
.macro TRAPPED cause, epc_sym
    .set NTRAP, NTRAP + 1
    CHECK x24, NTRAP
    CHECK x25, \cause
    la    x29, \epc_sym
    bne   x26, x29, fail
.endm

// mtval must equal the instruction word at mepc.
.macro TVAL_IS_INSN
    lw    x29, 0(x26)
    bne   x27, x29, fail
.endm

TEST_BEGIN
    la    t0, trap_handler
    csrw  mtvec, t0
    li    x24, 0

    li    TESTNUM, 1
    ARM
t1: ecall
    TRAPPED 11, t1
    CHECK x27, 0

    li    TESTNUM, 2
    ARM
t2: ebreak
    TRAPPED 3, t2
    CHECK x27, 0

    li    TESTNUM, 3
    ARM
t3: .word 0xffffffff
    TRAPPED 2, t3
    CHECK x27, 0xffffffff

    li    TESTNUM, 4
    ARM
t4: .word 0x00000000
    TRAPPED 2, t4
    CHECK x27, 0

    // Nonexistent CSR: illegal, rd not written.
    li    TESTNUM, 5
    ARM
    li    x3, 0x55
t5: csrr  x3, 0x7c0
    TRAPPED 2, t5
    TVAL_IS_INSN
    CHECK x3, 0x55

    // Writes to read-only CSRs (address[11:10] = 11) are illegal; reads are not.
    li    TESTNUM, 6
    ARM
t6: csrw  mhartid, x1
    TRAPPED 2, t6
    TVAL_IS_INSN
    li    TESTNUM, 7
    ARM
t7: csrrs x3, cycle, x1
    TRAPPED 2, t7
    li    TESTNUM, 8
    ARM
t8: csrrci x3, mvendorid, 1
    TRAPPED 2, t8
    li    TESTNUM, 9
    csrrs x3, cycle, x0
    csrrsi x3, mvendorid, 0
    csrrc x3, instret, x0
    CHECK x24, NTRAP

    // Bad encodings.
    li    TESTNUM, 10
    ARM
t10: .word 0x0000007f               // unknown opcode
    TRAPPED 2, t10
    TVAL_IS_INSN
    li    TESTNUM, 11
    ARM
t11: .word 0x0000100f               // FENCE.I (no Zifencei)
    TRAPPED 2, t11
    li    TESTNUM, 12
    ARM
t12: .word 0x02109093               // slli with imm[5] set
    TRAPPED 2, t12
    li    TESTNUM, 13
    ARM
t13: .word 0x022081b3               // mul (no M)
    TRAPPED 2, t13
    li    TESTNUM, 14
    ARM
t14: .word 0x40001093               // slli with funct7 0x20
    TRAPPED 2, t14
    li    TESTNUM, 15
    ARM
t15: .word 0x00003003               // load funct3 = 3 (ld)
    TRAPPED 2, t15
    li    TESTNUM, 16
    ARM
t16: .word 0x00003023               // store funct3 = 3 (sd)
    TRAPPED 2, t16
    li    TESTNUM, 17
    ARM
t17: .word 0x00002063               // branch funct3 = 2
    TRAPPED 2, t17
    li    TESTNUM, 18
    ARM
t18: .word 0x00001067               // jalr funct3 = 1
    TRAPPED 2, t18
    li    TESTNUM, 19
    ARM
t19: .word 0x00200073               // SYSTEM funct3 = 0, not ecall/ebreak/mret/wfi
    TRAPPED 2, t19
    li    TESTNUM, 20
    ARM
t20: .word 0x00004073               // SYSTEM funct3 = 4
    TRAPPED 2, t20
    li    TESTNUM, 21
    fence iorw, iorw                // legal
    wfi
    CHECK x24, NTRAP

    // Load address misaligned: mtval = address, rd not written.
    li    TESTNUM, 22
    ARM
    la    x1, tdat
    li    x3, 0x77
t22: lw   x3, 1(x1)
    TRAPPED 4, t22
    addi  x2, x1, 1
    bne   x27, x2, fail
    CHECK x3, 0x77
    li    TESTNUM, 23
    ARM
t23: lh   x3, 3(x1)
    TRAPPED 4, t23
    addi  x2, x1, 3
    bne   x27, x2, fail
    li    TESTNUM, 24
    ARM
t24: lhu  x3, 1(x1)
    TRAPPED 4, t24
    li    TESTNUM, 25
    ARM
t25: lw   x3, 2(x1)
    TRAPPED 4, t25
    li    TESTNUM, 26
    lb    x3, 3(x1)                 // byte loads never misalign
    lhu   x3, 2(x1)
    CHECK x24, NTRAP

    // Store address misaligned: mtval = address, memory unchanged.
    li    TESTNUM, 27
    ARM
    li    x2, 0x12345678
t27: sw   x2, 2(x1)
    TRAPPED 6, t27
    addi  x4, x1, 2
    bne   x27, x4, fail
    lw    x3, 0(x1)
    CHECK x3, 0x00ff00ff
    lw    x3, 4(x1)
    CHECK x3, 0xff00ff00
    li    TESTNUM, 28
    ARM
t28: sh   x2, 1(x1)
    TRAPPED 6, t28
    lw    x3, 0(x1)
    CHECK x3, 0x00ff00ff
    li    TESTNUM, 29
    ARM
t29: sw   x2, 3(x1)
    TRAPPED 6, t29

    // Instruction address misaligned: mcause 0, mtval = target, rd not written.
    li    TESTNUM, 30
    ARM
    li    x1, 0x99
t30: jal  x1, jtgt + 2
    TRAPPED 0, t30
    la    x2, jtgt + 2
    bne   x27, x2, fail
    CHECK x1, 0x99
    li    TESTNUM, 31
    ARM
    la    x2, jtgt
t31: jalr x1, 2(x2)
    TRAPPED 0, t31
    addi  x4, x2, 2
    bne   x27, x4, fail
    CHECK x1, 0x99
    li    TESTNUM, 32
    ARM
t32: jalr x1, 3(x2)                 // (x2 + 3) & ~1 = x2 + 2
    TRAPPED 0, t32
    addi  x4, x2, 2
    bne   x27, x4, fail
    li    TESTNUM, 33
    ARM
t33: beq  x0, x0, jtgt + 2
    TRAPPED 0, t33
    la    x4, jtgt + 2
    bne   x27, x4, fail
    li    TESTNUM, 34
    bne   x0, x0, jtgt + 2          // not taken: no trap
    CHECK x24, NTRAP

    // mstatus on trap entry and MRET.
    li    TESTNUM, 35
    csrw  mie, x0
    csrsi mstatus, 8                // MIE = 1 (mie = 0: no interrupts)
    ecall
    CHECK x23, 0x1880               // in handler: MIE = 0, MPIE = 1
    csrr  x3, mstatus
    CHECK x3, 0x1888                // after mret: MIE = MPIE = 1
    li    TESTNUM, 36
    csrw  mstatus, x0
    ecall
    CHECK x23, 0x1800
    csrr  x3, mstatus
    CHECK x3, 0x1880
    csrw  mstatus, x0

    // MRET outside a handler: pc = mepc, MIE = MPIE, MPIE = 1.
    li    TESTNUM, 37
    la    x1, after_mret
    csrw  mepc, x1
    mret
    j     fail
after_mret:
    csrr  x3, mstatus
    CHECK x3, 0x1880                // MIE = MPIE (0), MPIE = 1
    csrw  mstatus, x0

    // A trapping instruction does not retire: minstret skips it, counts the handler.
    li    TESTNUM, 38
    csrr  x1, minstret
    ecall
    csrr  x2, minstret
    sub   x3, x2, x1
    CHECK x3, 9                     // csrr + 8 handler instructions
    j     pass

    .balign 4
jtgt:
    j     fail
    j     fail

    .balign 4
trap_handler:
    csrr  x25, mcause
    csrr  x26, mepc
    csrr  x27, mtval
    csrr  x23, mstatus
    addi  x24, x24, 1
    addi  x22, x26, 4
    csrw  mepc, x22
    mret
TEST_END

    .data
    .balign 4
tdat:
    .word 0x00ff00ff, 0xff00ff00
