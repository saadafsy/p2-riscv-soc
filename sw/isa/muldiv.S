// M extension: mul mulh mulhsu mulhu div divu rem remu, the divide-by-zero and
// overflow results, forwarding into and out of M instructions.
#include "isa.h"
TEST_BEGIN
    TEST_RR  1, mul, 0x00000015, 0x00000003, 0x00000007
    TEST_RR  2, mul, 0x00000001, 0xffffffff, 0xffffffff
    TEST_RR  3, mul, 0x00000000, 0x80000000, 0x00000002
    TEST_RR  4, mul, 0x00000001, 0x7fffffff, 0x7fffffff
    TEST_RR  5, mul, 0xfffffffb, 0xffffffff, 0x00000005

    TEST_RR 10, mulh, 0x00000000, 0xffffffff, 0xffffffff
    TEST_RR 11, mulh, 0x40000000, 0x80000000, 0x80000000
    TEST_RR 12, mulh, 0xc0000000, 0x80000000, 0x7fffffff
    TEST_RR 13, mulh, 0xffffffff, 0xffffffff, 0x00000001
    TEST_RR 14, mulh, 0x3fffffff, 0x7fffffff, 0x7fffffff

    TEST_RR 20, mulhsu, 0xffffffff, 0xffffffff, 0xffffffff
    TEST_RR 21, mulhsu, 0x80000000, 0x80000000, 0xffffffff
    TEST_RR 22, mulhsu, 0x7ffffffe, 0x7fffffff, 0xffffffff
    TEST_RR 23, mulhsu, 0x00000001, 0x00000002, 0x80000000
    TEST_RR 24, mulhsu, 0xffffffff, 0xfffffffe, 0x00000003

    TEST_RR 30, mulhu, 0xfffffffe, 0xffffffff, 0xffffffff
    TEST_RR 31, mulhu, 0x00000001, 0x80000000, 0x00000002
    TEST_RR 32, mulhu, 0x40000000, 0x80000000, 0x80000000
    TEST_RR 33, mulhu, 0x00000000, 0xffffffff, 0x00000001

    TEST_RR 40, div, 0x00000003, 20, 6
    TEST_RR 41, div, 0xfffffffd, -20, 6
    TEST_RR 42, div, 0xfffffffd, 20, -6
    TEST_RR 43, div, 0x00000003, -20, -6
    TEST_RR 44, div, 0xffffffff, 5, 0                // divide by zero
    TEST_RR 45, div, 0xffffffff, -5, 0
    TEST_RR 46, div, 0x80000000, 0x80000000, -1      // overflow
    TEST_RR 47, div, 0xfffffffd, -7, 2               // rounds toward zero

    TEST_RR 50, divu, 0x00000003, 20, 6
    TEST_RR 51, divu, 0x00000001, 0xffffffff, 0xffffffff
    TEST_RR 52, divu, 0x00000000, 0x80000000, 0xffffffff
    TEST_RR 53, divu, 0xffffffff, 5, 0
    TEST_RR 54, divu, 0x7fffffff, 0xfffffffe, 2

    TEST_RR 60, rem, 0x00000002, 20, 6
    TEST_RR 61, rem, 0xfffffffe, -20, 6
    TEST_RR 62, rem, 0x00000002, 20, -6
    TEST_RR 63, rem, 0xfffffffe, -20, -6
    TEST_RR 64, rem, 0x00000005, 5, 0                // divide by zero: dividend
    TEST_RR 65, rem, 0xfffffffb, -5, 0
    TEST_RR 66, rem, 0x00000000, 0x80000000, -1      // overflow
    TEST_RR 67, rem, 0xfffffffe, 0x80000000, 3

    TEST_RR 70, remu, 0x00000002, 20, 6
    TEST_RR 71, remu, 0xffffffff, 0xffffffff, 0
    TEST_RR 72, remu, 0x00000005, 0xffffffff, 10
    TEST_RR 73, remu, 0x80000000, 0x80000000, 0xffffffff

    // operand and result forwarding distances
    TEST_RR_D 80, 1, mul, 0x00000015, 3, 7
    TEST_RR_D 81, 2, mul, 0x00000015, 3, 7
    TEST_RR_D 82, 1, div, 0xfffffffd, -20, 6
    TEST_RR_D 83, 2, remu, 0x00000005, 0xffffffff, 10
    TEST_RR_SRC1EQDEST 84, mul, 0x00000051, 9, 9
    TEST_RR_SRC2EQDEST 85, divu, 0x00000004, 9, 2
    TEST_RR_SRC12EQDEST 86, mulhu, 0xfffffffe, 0xffffffff
    TEST_RR_ZERODEST 87, mul, 3, 7
    TEST_RR_ZERODEST 88, div, 3, 0
    TEST_RR_ZEROSRC1 89, div, 0x00000000, 5
    TEST_RR_ZEROSRC2 90, rem, 0x00000007, 7

    // back-to-back dependent M instructions
    li    TESTNUM, 91
    li    x1, 6
    li    x2, 7
    mul   x3, x1, x2
    mul   x3, x3, x3                // 1764
    divu  x3, x3, x1                // 294
    rem   x4, x3, x2                // 0
    div   x3, x3, x2                // 42
    mulh  x4, x3, x4                // 0
    CHECK x3, 42
    CHECK x4, 0

    // load feeding an M instruction, M result feeding a store and a branch
    li    TESTNUM, 92
    la    x1, mdat
    lw    x2, 0(x1)                 // 1000
    div   x3, x2, x2
    lw    x2, 4(x1)                 // -3
    mul   x3, x2, x2
    sw    x3, 8(x1)
    lw    x4, 8(x1)
    CHECK x4, 9
    remu  x3, x4, x4
    bnez  x3, fail
    mul   x3, x4, x4
    li    x2, 81
    bne   x3, x2, fail
TEST_END

    .data
    .balign 4
mdat: .word 1000, -3, 0
