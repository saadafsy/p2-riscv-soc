// I-type ALU: addi slti sltiu xori ori andi slli srli srai (12-bit sign-extended imm).
#include "isa.h"
TEST_BEGIN
    TEST_RI  1, addi, 0x00000000, 0x00000000, 0
    TEST_RI  2, addi, 0x00000002, 0x00000001, 1
    TEST_RI  3, addi, 0xfffff800, 0x00000000, -2048
    TEST_RI  4, addi, 0x000007ff, 0x00000000, 2047
    TEST_RI  5, addi, 0x800007fe, 0x7fffffff, 2047
    TEST_RI  6, addi, 0x7ffff800, 0x80000000, -2048
    TEST_RI  7, addi, 0x00000000, 0xffffffff, 1
    TEST_RI  8, addi, 0xfffffffe, 0xffffffff, -1

    TEST_RI  9, slti, 1, 0xffffffff, 0
    TEST_RI 10, slti, 0, 0x00000000, -1
    TEST_RI 11, slti, 1, 0x80000000, -2048
    TEST_RI 12, slti, 0, 0x7fffffff, 2047
    TEST_RI 13, slti, 0, 0x000007ff, 2047
    TEST_RI 14, slti, 1, 0xfffff7ff, -2048

    TEST_RI 15, sltiu, 1, 0x00000000, -1       // imm sign-extends to 0xffffffff
    TEST_RI 16, sltiu, 0, 0xffffffff, -1
    TEST_RI 17, sltiu, 1, 0x7fffffff, -2048
    TEST_RI 18, sltiu, 0, 0x80000000, 2047
    TEST_RI 19, sltiu, 1, 0x00000000, 1
    TEST_RI 20, sltiu, 0, 0x00000001, 1

    TEST_RI 21, xori, 0xff00f0ff, 0x00ff0f00, -1
    TEST_RI 22, xori, 0x00ff0ff0, 0x00ff0f00, 0x0f0
    TEST_RI 23, xori, 0xff00f70f, 0x00ff0f00, -2033

    TEST_RI 24, ori, 0xffffff0f, 0xff00ff00, -241
    TEST_RI 25, ori, 0x0ff00ff0, 0x0ff00ff0, 0x0f0
    TEST_RI 26, ori, 0x00ff07ff, 0x00ff00ff, 0x70f

    TEST_RI 27, andi, 0xff00ff00, 0xff00ff00, -241
    TEST_RI 28, andi, 0x000000f0, 0x0ff00ff0, 0x0f0
    TEST_RI 29, andi, 0x0000000f, 0x00ff00ff, 0x70f

    TEST_RI 30, slli, 0x00000001, 0x00000001, 0
    TEST_RI 31, slli, 0x80000000, 0x00000001, 31
    TEST_RI 32, slli, 0xffffc000, 0xffffffff, 14
    TEST_RI 33, slli, 0x80000000, 0x21212121, 31

    TEST_RI 34, srli, 0x80000000, 0x80000000, 0
    TEST_RI 35, srli, 0x00000001, 0x80000000, 31
    TEST_RI 36, srli, 0x7fffffff, 0xffffffff, 1
    TEST_RI 37, srli, 0x00008484, 0x21212121, 14

    TEST_RI 38, srai, 0x80000000, 0x80000000, 0
    TEST_RI 39, srai, 0xc0000000, 0x80000000, 1
    TEST_RI 40, srai, 0xffffffff, 0x80000000, 31
    TEST_RI 41, srai, 0x00000000, 0x7fffffff, 31
    TEST_RI 42, srai, 0xff030303, 0x81818181, 7

    TEST_RI_SRC1EQDEST 43, addi, 24, 13, 11
    TEST_RI_SRC1EQDEST 44, srai, 0xfffffff8, 0xffffff80, 4
    TEST_RI_ZERODEST   45, addi, 5, 7
    TEST_RI_ZERODEST   46, slli, 0xffffffff, 3
    TEST_RI_ZEROSRC1   47, addi, 32, 32
    TEST_RI_ZEROSRC1   48, ori, 0xfffff800, -2048
    TEST_RI_D          49, 1, addi, 24, 13, 11
    TEST_RI_D          50, 2, srai, 0xff030303, 0x81818181, 7
    TEST_RI_D          51, 3, sltiu, 1, 0, -1

    // nop is addi x0, x0, 0; it must leave x0 at zero.
    li    TESTNUM, 52
    nop
    addi  x0, x0, 1
    mv    x3, x0
    bnez  x3, fail
    j     pass
TEST_END
