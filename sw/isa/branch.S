// Conditional branches: taken and not taken, signed/unsigned edges, flush, loops.
#include "isa.h"
TEST_BEGIN
    TEST_BR_T  1, beq,  0, 0
    TEST_BR_T  2, beq,  1, 1
    TEST_BR_T  3, beq,  -1, -1
    TEST_BR_N  4, beq,  0, 1
    TEST_BR_N  5, beq,  1, 0
    TEST_BR_N  6, beq,  -1, 1

    TEST_BR_T  7, bne,  0, 1
    TEST_BR_T  8, bne,  1, 0
    TEST_BR_T  9, bne,  -1, 1
    TEST_BR_N 10, bne,  0, 0
    TEST_BR_N 11, bne,  1, 1
    TEST_BR_N 12, bne,  -1, -1

    TEST_BR_T 13, blt,  0, 1
    TEST_BR_T 14, blt,  -1, 1
    TEST_BR_T 15, blt,  -2, -1
    TEST_BR_T 16, blt,  0x80000000, 0x7fffffff
    TEST_BR_N 17, blt,  1, 0
    TEST_BR_N 18, blt,  1, -1
    TEST_BR_N 19, blt,  -1, -2
    TEST_BR_N 20, blt,  5, 5
    TEST_BR_N 21, blt,  0x7fffffff, 0x80000000

    TEST_BR_T 22, bge,  0, 0
    TEST_BR_T 23, bge,  1, 1
    TEST_BR_T 24, bge,  -1, -1
    TEST_BR_T 25, bge,  1, 0
    TEST_BR_T 26, bge,  1, -1
    TEST_BR_T 27, bge,  0x7fffffff, 0x80000000
    TEST_BR_N 28, bge,  0, 1
    TEST_BR_N 29, bge,  -1, 1
    TEST_BR_N 30, bge,  -2, -1
    TEST_BR_N 31, bge,  0x80000000, 0x7fffffff

    TEST_BR_T 32, bltu, 0, 1
    TEST_BR_T 33, bltu, 0xfffffffe, 0xffffffff
    TEST_BR_T 34, bltu, 0, 0xffffffff
    TEST_BR_T 35, bltu, 0x7fffffff, 0x80000000
    TEST_BR_N 36, bltu, 1, 0
    TEST_BR_N 37, bltu, 0xffffffff, 0xfffffffe
    TEST_BR_N 38, bltu, 0xffffffff, 0
    TEST_BR_N 39, bltu, 0x80000000, 0x7fffffff
    TEST_BR_N 40, bltu, 5, 5

    TEST_BR_T 41, bgeu, 0, 0
    TEST_BR_T 42, bgeu, 1, 1
    TEST_BR_T 43, bgeu, 0xffffffff, 0xffffffff
    TEST_BR_T 44, bgeu, 1, 0
    TEST_BR_T 45, bgeu, 0xffffffff, 0
    TEST_BR_T 46, bgeu, 0x80000000, 0x7fffffff
    TEST_BR_N 47, bgeu, 0, 1
    TEST_BR_N 48, bgeu, 0, 0xffffffff
    TEST_BR_N 49, bgeu, 0x7fffffff, 0x80000000

    // Instructions after a taken branch must not execute.
    li    TESTNUM, 50
    li    x3, 0
    beq   x0, x0, 1f
    addi  x3, x3, 1
    addi  x3, x3, 1
1:  CHECK x3, 0

    // Backward branch loop.
    li    TESTNUM, 51
    li    x1, 5
    li    x3, 0
2:  addi  x3, x3, 1
    addi  x1, x1, -1
    bnez  x1, 2b
    CHECK x3, 5

    // Branch on a value produced by the previous instruction (forwarding).
    li    TESTNUM, 52
    li    x1, 7
    addi  x2, x1, -7
    bnez  x2, fail
    addi  x2, x2, 1
    beqz  x2, fail

    // Taken branch on the instruction right after a load (load-use into the branch).
    li    TESTNUM, 53
    la    x1, bdata
    lw    x2, 0(x1)
    bne   x2, x0, 3f
    j     fail
3:
    // Long forward branch across 1 KB.
    li    TESTNUM, 54
    bgeu  x0, x0, 4f
    .rept 256
    j     fail
    .endr
4:  j     pass
TEST_END

    .data
    .balign 4
bdata: .word 0x55
