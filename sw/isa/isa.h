// Self-checking ISA test harness. x28 holds the current test number; the run ends
// with SIMCTRL EXIT = 0 (pass) or the failing test number. An unexpected trap fails
// the current test. Tests use x1-x4 as scratch and x29 for expected values.
#include "soc.h"

#define TESTNUM x28

.macro TEST_BEGIN
    .section .text.init, "ax"
    .globl _start
_start:
    li    TESTNUM, 0xFFFF
    la    t0, unexpected_trap
    csrw  mtvec, t0
.endm

.macro TEST_END
pass:
    li    t0, SIMCTRL_EXIT
    sw    zero, 0(t0)
1:  j     1b
fail:
    li    t0, SIMCTRL_EXIT
    sw    TESTNUM, 0(t0)
2:  j     2b
    .balign 4
unexpected_trap:
    j     fail
.endm

.macro CHECK reg, exp
    li    x29, \exp
    bne   \reg, x29, fail
.endm

.macro TEST_RR n, inst, exp, a, b
    li    TESTNUM, \n
    li    x1, \a
    li    x2, \b
    \inst x3, x1, x2
    CHECK x3, \exp
.endm

// Same, with `d` nops between the operand writes, the operation and the check.
.macro TEST_RR_D n, d, inst, exp, a, b
    li    TESTNUM, \n
    li    x1, \a
    .rept \d
    nop
    .endr
    li    x2, \b
    .rept \d
    nop
    .endr
    \inst x3, x1, x2
    .rept \d
    nop
    .endr
    CHECK x3, \exp
.endm

.macro TEST_RR_SRC1EQDEST n, inst, exp, a, b
    li    TESTNUM, \n
    li    x1, \a
    li    x2, \b
    \inst x1, x1, x2
    CHECK x1, \exp
.endm

.macro TEST_RR_SRC2EQDEST n, inst, exp, a, b
    li    TESTNUM, \n
    li    x1, \a
    li    x2, \b
    \inst x2, x1, x2
    CHECK x2, \exp
.endm

.macro TEST_RR_SRC12EQDEST n, inst, exp, a
    li    TESTNUM, \n
    li    x1, \a
    \inst x1, x1, x1
    CHECK x1, \exp
.endm

.macro TEST_RR_ZERODEST n, inst, a, b
    li    TESTNUM, \n
    li    x1, \a
    li    x2, \b
    \inst x0, x1, x2
    addi  x3, x0, 0
    bnez  x3, fail
.endm

.macro TEST_RR_ZEROSRC1 n, inst, exp, b
    li    TESTNUM, \n
    li    x2, \b
    \inst x3, x0, x2
    CHECK x3, \exp
.endm

.macro TEST_RR_ZEROSRC2 n, inst, exp, a
    li    TESTNUM, \n
    li    x1, \a
    \inst x3, x1, x0
    CHECK x3, \exp
.endm

.macro TEST_RI n, inst, exp, a, imm
    li    TESTNUM, \n
    li    x1, \a
    \inst x3, x1, \imm
    CHECK x3, \exp
.endm

.macro TEST_RI_D n, d, inst, exp, a, imm
    li    TESTNUM, \n
    li    x1, \a
    .rept \d
    nop
    .endr
    \inst x3, x1, \imm
    .rept \d
    nop
    .endr
    CHECK x3, \exp
.endm

.macro TEST_RI_SRC1EQDEST n, inst, exp, a, imm
    li    TESTNUM, \n
    li    x1, \a
    \inst x1, x1, \imm
    CHECK x1, \exp
.endm

.macro TEST_RI_ZERODEST n, inst, a, imm
    li    TESTNUM, \n
    li    x1, \a
    \inst x0, x1, \imm
    addi  x3, x0, 0
    bnez  x3, fail
.endm

.macro TEST_RI_ZEROSRC1 n, inst, exp, imm
    li    TESTNUM, \n
    \inst x3, x0, \imm
    CHECK x3, \exp
.endm

// Branch must be taken / not taken.
.macro TEST_BR_T n, inst, a, b
    li    TESTNUM, \n
    li    x1, \a
    li    x2, \b
    \inst x1, x2, 1f
    j     fail
1:
.endm

.macro TEST_BR_N n, inst, a, b
    li    TESTNUM, \n
    li    x1, \a
    li    x2, \b
    \inst x1, x2, fail
.endm

// Load from base symbol `sym` + `off` (base register holds sym).
.macro TEST_LD n, inst, exp, sym, off
    li    TESTNUM, \n
    la    x1, \sym
    \inst x3, \off(x1)
    CHECK x3, \exp
.endm
