// JAL and JALR: link values, offsets, bit 0 clearing, rd == rs1, flush, calls.
#include "isa.h"

.macro LA_ABS reg, sym
    lui   \reg, %hi(\sym)
    addi  \reg, \reg, %lo(\sym)
.endm

TEST_BEGIN
    li    TESTNUM, 1
    jal   x1, 1f
ret1:
    j     fail
1:  LA_ABS x4, ret1
    bne   x1, x4, fail

    li    TESTNUM, 2
    li    x3, 0
    j     2f
    addi  x3, x3, 1
    addi  x3, x3, 1
2:  CHECK x3, 0

    li    TESTNUM, 3
    LA_ABS x2, t3
    jalr  x1, 0(x2)
ret3:
    j     fail
t3: LA_ABS x4, ret3
    bne   x1, x4, fail

    li    TESTNUM, 4
    LA_ABS x2, t4 - 8
    jalr  x1, 8(x2)
    j     fail
t4:
    li    TESTNUM, 5
    LA_ABS x2, t5 + 1               // target bit 0 is cleared
    jalr  x1, 0(x2)
    j     fail
t5:
    li    TESTNUM, 6
    LA_ABS x1, t6
    jalr  x1, 0(x1)                 // rd == rs1: target uses the old value
ret6:
    j     fail
t6: LA_ABS x4, ret6
    bne   x1, x4, fail

    li    TESTNUM, 7
    LA_ABS x2, t7 + 16
    jalr  x1, -16(x2)
    j     fail
t7:
    li    TESTNUM, 8
    li    x3, 0
    call  func
    call  func
    CHECK x3, 2

    li    TESTNUM, 9
    LA_ABS x2, t9
    li    x1, 0x1234
    jalr  x0, 0(x2)                 // no link
    j     fail
t9: CHECK x1, 0x1234

    li    TESTNUM, 10
    li    x3, 0
    LA_ABS x2, t10
    jalr  x0, 0(x2)
    addi  x3, x3, 1
    addi  x3, x3, 1
t10: CHECK x3, 0

    li    TESTNUM, 11
    jal   x0, 3f                    // jal x0 writes nothing
3:  mv    x3, x0
    bnez  x3, fail

    // jalr target from a register written by the previous instruction.
    li    TESTNUM, 12
    LA_ABS x1, t12 - 4
    addi  x2, x1, 4
    jalr  x0, 0(x2)
    j     fail
t12: j    pass

func:
    addi  x3, x3, 1
    ret
TEST_END
