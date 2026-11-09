// LUI and AUIPC.
#include "isa.h"
TEST_BEGIN
    li    TESTNUM, 1
    lui   x3, 0
    CHECK x3, 0
    li    TESTNUM, 2
    lui   x3, 0xfffff
    srai  x3, x3, 1
    CHECK x3, 0xfffff800
    li    TESTNUM, 3
    lui   x3, 0x7ffff
    CHECK x3, 0x7ffff000
    li    TESTNUM, 4
    lui   x3, 0x80000
    CHECK x3, 0x80000000
    li    TESTNUM, 5
    lui   x0, 0x80000
    mv    x3, x0
    bnez  x3, fail
    li    TESTNUM, 6
    lui   x3, 0x12345
    addi  x3, x3, 0x678
    CHECK x3, 0x12345678

    li    TESTNUM, 7
auipc0:
    auipc x3, 0
    lui   x4, %hi(auipc0)
    addi  x4, x4, %lo(auipc0)
    bne   x3, x4, fail
    li    TESTNUM, 8
auipc1:
    auipc x3, 1
    lui   x4, %hi(auipc1 + 0x1000)
    addi  x4, x4, %lo(auipc1 + 0x1000)
    bne   x3, x4, fail
    li    TESTNUM, 9
auipc2:
    auipc x3, 0xfffff               // pc - 0x1000, wraps below 0
    lui   x4, %hi(auipc2)
    addi  x4, x4, %lo(auipc2)
    li    x2, 0x1000
    sub   x4, x4, x2
    bne   x3, x4, fail
    li    TESTNUM, 10
    auipc x0, 0x12345
    mv    x3, x0
    bnez  x3, fail
    j     pass
TEST_END
