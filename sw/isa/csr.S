// Zicsr: all six forms, no-write forms, WARL masks, read-only values, counters.
#include "isa.h"
TEST_BEGIN
    li    TESTNUM, 1
    li    x1, 0x12345678
    csrw  mscratch, x1
    csrr  x3, mscratch
    CHECK x3, 0x12345678
    li    TESTNUM, 2
    li    x1, 0xa5a5a5a5
    csrrw x3, mscratch, x1
    CHECK x3, 0x12345678
    li    TESTNUM, 3
    li    x1, 0x0000ffff
    csrrs x3, mscratch, x1
    CHECK x3, 0xa5a5a5a5
    li    TESTNUM, 4
    li    x1, 0xff000000
    csrrc x3, mscratch, x1
    CHECK x3, 0xa5a5ffff
    csrr  x3, mscratch
    CHECK x3, 0x00a5ffff
    li    TESTNUM, 5
    csrrwi x3, mscratch, 0x1f
    CHECK x3, 0x00a5ffff
    li    TESTNUM, 6
    csrrsi x3, mscratch, 0           // no write
    CHECK x3, 0x1f
    li    TESTNUM, 7
    csrrci x3, mscratch, 0x05
    CHECK x3, 0x1f
    csrrsi x3, mscratch, 0x10
    CHECK x3, 0x1a
    li    TESTNUM, 8
    csrrs x3, mscratch, x0           // no write
    CHECK x3, 0x1a
    csrrc x3, mscratch, x0
    CHECK x3, 0x1a
    li    TESTNUM, 9
    li    x1, 0x600df00d
    csrrw x0, mscratch, x1           // rd = x0 still writes
    csrr  x3, mscratch
    CHECK x3, 0x600df00d
    // CSR result used by the next instruction.
    li    TESTNUM, 10
    csrr  x3, mscratch
    addi  x3, x3, 3
    CHECK x3, 0x600df010

    li    TESTNUM, 11
    csrr  x3, misa
    CHECK x3, 0x40001100
    csrw  misa, x0                  // ignored
    csrr  x3, misa
    CHECK x3, 0x40001100
    li    TESTNUM, 12
    csrr  x3, mhartid
    CHECK x3, 0
    csrr  x3, mvendorid
    CHECK x3, 0
    csrr  x3, marchid
    CHECK x3, 0
    csrr  x3, mimpid
    CHECK x3, 0

    li    TESTNUM, 13
    csrw  mstatus, x0
    csrr  x3, mstatus
    CHECK x3, 0x1800                // MPP reads 11
    li    x1, 0x00000080
    csrw  mstatus, x1
    csrr  x3, mstatus
    CHECK x3, 0x1880
    li    x1, -1                    // mie is 0, so MIE = 1 here cannot take an interrupt
    csrw  mie, x0
    csrw  mstatus, x1
    csrr  x3, mstatus
    CHECK x3, 0x1888
    csrw  mstatus, x0

    li    TESTNUM, 14
    li    x1, -1
    csrw  mie, x1
    csrr  x3, mie
    CHECK x3, 0x880
    csrw  mie, x0
    csrr  x3, mie
    CHECK x3, 0

    li    TESTNUM, 15
    li    x1, 0x12345677
    csrw  mtvec, x1
    csrr  x3, mtvec
    CHECK x3, 0x12345674
    la    x1, unexpected_trap
    csrw  mtvec, x1

    li    TESTNUM, 16
    li    x1, -1
    csrw  mepc, x1
    csrr  x3, mepc
    CHECK x3, 0xfffffffc
    li    x1, 0x8000000b
    csrw  mcause, x1
    csrr  x3, mcause
    CHECK x3, 0x8000000b
    li    x1, 0xdeadbeef
    csrw  mtval, x1
    csrr  x3, mtval
    CHECK x3, 0xdeadbeef

    // mip: timer compare is all-ones and no external source, so 0; writes ignored.
    li    TESTNUM, 17
    csrr  x3, mip
    CHECK x3, 0
    li    x1, -1
    csrw  mip, x1
    csrr  x3, mip
    CHECK x3, 0

    // minstret counts retired instructions; a read sees the value before itself.
    li    TESTNUM, 18
    csrr  x1, minstret
    csrr  x2, minstret
    sub   x3, x2, x1
    CHECK x3, 1
    csrr  x1, minstret
    nop
    nop
    csrr  x2, instret
    sub   x3, x2, x1
    CHECK x3, 3
    li    TESTNUM, 19
    li    x1, 100
    csrw  minstret, x1              // the write replaces this instruction's increment
    csrr  x3, minstret
    CHECK x3, 100
    li    TESTNUM, 20
    csrw  minstreth, x0
    li    x1, -1
    csrw  minstret, x1
    csrr  x3, minstreth             // reads 0, then minstret carries into minstreth
    csrr  x4, minstreth
    CHECK x3, 0
    CHECK x4, 1
    csrr  x3, instreth
    CHECK x3, 1
    li    x1, 5
    csrw  minstreth, x1
    csrr  x3, minstreth
    CHECK x3, 5

    // mcycle: writable, counts up; mcycleh writable; shadows match.
    li    TESTNUM, 21
    csrw  mcycle, x0
    csrr  x1, mcycle
    nop
    csrr  x2, mcycle
    bgeu  x1, x2, fail
    li    x1, 7
    csrw  mcycleh, x1
    csrr  x3, mcycleh
    CHECK x3, 7
    csrr  x3, cycleh
    CHECK x3, 7
    csrr  x1, cycle
    csrr  x2, mcycle
    bltu  x2, x1, fail

    // FENCE and WFI execute as no-ops.
    li    TESTNUM, 22
    li    x3, 9
    fence
    fence rw, rw
    wfi
    CHECK x3, 9
    j     pass
TEST_END
