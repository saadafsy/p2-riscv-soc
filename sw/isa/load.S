// Loads: lb lh lw lbu lhu at every offset, sign/zero extension, negative offsets,
// x0 destination, load-use, pointer chasing, peripheral and unmapped reads.
#include "isa.h"
TEST_BEGIN
    TEST_LD  1, lb,  0xffffffff, tdat, 0
    TEST_LD  2, lb,  0x00000000, tdat, 1
    TEST_LD  3, lb,  0xffffffff, tdat, 2
    TEST_LD  4, lb,  0x00000000, tdat, 3
    TEST_LD  5, lb,  0xffffffff, tdat, 5
    TEST_LD  6, lb,  0xfffffff0, tdat, 8
    TEST_LD  7, lb,  0x0000000f, tdat, 9

    TEST_LD  8, lbu, 0x000000ff, tdat, 0
    TEST_LD  9, lbu, 0x00000000, tdat, 1
    TEST_LD 10, lbu, 0x000000f0, tdat, 8
    TEST_LD 11, lbu, 0x000000f0, tdat, 13
    TEST_LD 12, lbu, 0x0000000f, tdat, 14

    TEST_LD 13, lh,  0x000000ff, tdat, 0
    TEST_LD 14, lh,  0x000000ff, tdat, 2
    TEST_LD 15, lh,  0xffffff00, tdat, 4
    TEST_LD 16, lh,  0xffffff00, tdat, 6
    TEST_LD 17, lh,  0x00000ff0, tdat, 8
    TEST_LD 18, lh,  0x00000ff0, tdat, 10
    TEST_LD 19, lh,  0xfffff00f, tdat, 12
    TEST_LD 20, lh,  0xfffff00f, tdat, 14

    TEST_LD 21, lhu, 0x000000ff, tdat, 0
    TEST_LD 22, lhu, 0x0000ff00, tdat, 4
    TEST_LD 23, lhu, 0x0000ff00, tdat, 6
    TEST_LD 24, lhu, 0x0000f00f, tdat, 12

    TEST_LD 25, lw,  0x00ff00ff, tdat, 0
    TEST_LD 26, lw,  0xff00ff00, tdat, 4
    TEST_LD 27, lw,  0x0ff00ff0, tdat, 8
    TEST_LD 28, lw,  0xf00ff00f, tdat, 12

    TEST_LD 29, lw,  0x00ff00ff, tdat_end, -16
    TEST_LD 30, lb,  0xfffffff0, tdat_end, -8
    TEST_LD 31, lhu, 0x0000f00f, tdat_end, -2

    // Unaligned base, aligned effective address.
    li    TESTNUM, 32
    la    x1, tdat
    addi  x1, x1, 1
    lw    x3, 3(x1)
    CHECK x3, 0xff00ff00

    li    TESTNUM, 33
    la    x1, tdat
    lw    x0, 0(x1)
    mv    x3, x0
    bnez  x3, fail

    // Load-use: consumer immediately after the load.
    li    TESTNUM, 34
    la    x1, tdat
    lw    x3, 4(x1)
    addi  x4, x3, 1
    CHECK x4, 0xff00ff01
    li    TESTNUM, 35
    la    x1, tdat
    lbu   x3, 0(x1)
    add   x4, x3, x3
    CHECK x4, 0x1fe

    // Pointer chase: loaded value is the next base.
    li    TESTNUM, 36
    la    x1, tptr
    lw    x1, 0(x1)
    lw    x3, 0(x1)
    CHECK x3, 0xff00ff00

    // Peripherals: TIMER MTIMECMP resets to all-ones; SIMCTRL and unmapped read 0.
    li    TESTNUM, 37
    li    x1, TIMER_BASE
    lw    x3, 8(x1)
    CHECK x3, 0xffffffff
    lw    x3, 12(x1)
    CHECK x3, 0xffffffff
    li    TESTNUM, 38
    li    x1, SIMCTRL_BASE
    lw    x3, 0(x1)
    CHECK x3, 0
    li    TESTNUM, 39
    li    x1, 0x30000000
    lw    x3, 0(x1)
    CHECK x3, 0
    lb    x3, 3(x1)
    CHECK x3, 0
    j     pass
TEST_END

    .data
    .balign 4
tdat:
    .word 0x00ff00ff, 0xff00ff00, 0x0ff00ff0, 0xf00ff00f
tdat_end:
tptr:
    .word tdat + 4
