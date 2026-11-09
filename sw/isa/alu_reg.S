// R-type ALU: add sub sll slt sltu xor srl sra or and.
#include "isa.h"
TEST_BEGIN
    TEST_RR  1, add, 0x00000000, 0x00000000, 0x00000000
    TEST_RR  2, add, 0x00000002, 0x00000001, 0x00000001
    TEST_RR  3, add, 0x0000000a, 0x00000003, 0x00000007
    TEST_RR  4, add, 0xffff8000, 0x00000000, 0xffff8000
    TEST_RR  5, add, 0x80000000, 0x80000000, 0x00000000
    TEST_RR  6, add, 0x7fff8000, 0x80000000, 0xffff8000
    TEST_RR  7, add, 0x80007ffe, 0x7fffffff, 0x00007fff
    TEST_RR  8, add, 0x80000000, 0x7fffffff, 0x00000001
    TEST_RR  9, add, 0x00000000, 0xffffffff, 0x00000001
    TEST_RR 10, add, 0xfffffffe, 0xffffffff, 0xffffffff

    TEST_RR 11, sub, 0x00000000, 0x00000000, 0x00000000
    TEST_RR 12, sub, 0x00000000, 0x00000001, 0x00000001
    TEST_RR 13, sub, 0xfffffffc, 0x00000003, 0x00000007
    TEST_RR 14, sub, 0x80000000, 0x00000000, 0x80000000
    TEST_RR 15, sub, 0x7fffffff, 0x80000000, 0x00000001
    TEST_RR 16, sub, 0xffffffff, 0x00000000, 0x00000001

    TEST_RR 17, sll, 0x00000001, 0x00000001, 0
    TEST_RR 18, sll, 0x80000000, 0x00000001, 31
    TEST_RR 19, sll, 0xffffff80, 0xffffffff, 7
    TEST_RR 20, sll, 0x48484000, 0x21212121, 14
    TEST_RR 21, sll, 0x00000002, 0x00000001, 0xffffffe1   // only rs2[4:0] used
    TEST_RR 22, sll, 0x80000000, 0x21212121, 0xffffffff
    TEST_RR 23, sll, 0x00000001, 0x00000001, 32

    TEST_RR 24, slt, 0, 0x00000000, 0x00000000
    TEST_RR 25, slt, 1, 0xffffffff, 0x00000000
    TEST_RR 26, slt, 0, 0x00000000, 0xffffffff
    TEST_RR 27, slt, 1, 0x80000000, 0x7fffffff
    TEST_RR 28, slt, 0, 0x7fffffff, 0x80000000
    TEST_RR 29, slt, 1, 0x00000003, 0x00000007

    TEST_RR 30, sltu, 0, 0xffffffff, 0x00000000
    TEST_RR 31, sltu, 1, 0x00000000, 0xffffffff
    TEST_RR 32, sltu, 0, 0x80000000, 0x7fffffff
    TEST_RR 33, sltu, 1, 0x7fffffff, 0x80000000
    TEST_RR 34, sltu, 0, 0x00000005, 0x00000005

    TEST_RR 35, xor, 0xf00ff00f, 0xff00ff00, 0x0f0f0f0f
    TEST_RR 36, xor, 0xff00ff00, 0x00ff00ff, 0xffffffff

    TEST_RR 37, srl, 0x40000000, 0x80000000, 1
    TEST_RR 38, srl, 0x00000001, 0x80000000, 31
    TEST_RR 39, srl, 0xffffffff, 0xffffffff, 0
    TEST_RR 40, srl, 0x00008484, 0x21212121, 14
    TEST_RR 41, srl, 0x40000000, 0x80000000, 0xffffffe1

    TEST_RR 42, sra, 0xc0000000, 0x80000000, 1
    TEST_RR 43, sra, 0xffffffff, 0x80000000, 31
    TEST_RR 44, sra, 0x00000000, 0x7fffffff, 31
    TEST_RR 45, sra, 0xff030303, 0x81818181, 7
    TEST_RR 46, sra, 0x81818181, 0x81818181, 0xffffffc0

    TEST_RR 47, or, 0xff0fff0f, 0xff00ff00, 0x0f0f0f0f
    TEST_RR 48, or, 0xffffffff, 0x00ff00ff, 0xff00ff00

    TEST_RR 49, and, 0x0f000f00, 0xff00ff00, 0x0f0f0f0f
    TEST_RR 50, and, 0x00000000, 0x00ff00ff, 0xff00ff00

    TEST_RR_SRC1EQDEST  51, add, 24, 13, 11
    TEST_RR_SRC2EQDEST  52, sub, 2, 13, 11
    TEST_RR_SRC12EQDEST 53, add, 26, 13
    TEST_RR_ZERODEST    54, add, 1, 2
    TEST_RR_ZERODEST    55, sra, 0x80000000, 4
    TEST_RR_ZEROSRC1    56, sub, 0xfffffff1, 15
    TEST_RR_ZEROSRC2    57, sll, 0x00001234, 0x1234
    TEST_RR_D           58, 1, add, 24, 13, 11
    TEST_RR_D           59, 2, xor, 0xf00ff00f, 0xff00ff00, 0x0f0f0f0f
    TEST_RR_D           60, 3, sra, 0xff030303, 0x81818181, 7

    // Back-to-back dependent chain (forwarding).
    li    TESTNUM, 61
    li    x1, 1
    add   x1, x1, x1
    add   x1, x1, x1
    add   x1, x1, x1
    add   x1, x1, x1
    add   x1, x1, x1
    CHECK x1, 32
    li    TESTNUM, 62
    li    x1, 5
    li    x2, 3
    sub   x3, x1, x2
    sll   x4, x3, x3
    or    x3, x4, x1
    CHECK x3, 0x0d
    j     pass
TEST_END
