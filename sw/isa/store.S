// Stores: sw sh sb at every offset, byte lanes, high rs2 bits ignored, negative
// offsets, store-to-load, sub-word stores to a peripheral register, unmapped writes.
#include "isa.h"
TEST_BEGIN
    li    TESTNUM, 1
    la    x1, sdat
    li    x2, 0xaa00aa00
    sw    x2, 0(x1)
    lw    x3, 0(x1)
    CHECK x3, 0xaa00aa00

    li    TESTNUM, 2
    la    x1, sdat + 4              // 0xdeadbeef
    li    x2, 0x11
    sb    x2, 0(x1)
    lw    x3, 0(x1)
    CHECK x3, 0xdeadbe11
    li    TESTNUM, 3
    li    x2, 0xffffff22            // only the low byte is stored
    sb    x2, 1(x1)
    lw    x3, 0(x1)
    CHECK x3, 0xdead2211
    li    TESTNUM, 4
    li    x2, 0x33
    sb    x2, 2(x1)
    li    x2, 0x44
    sb    x2, 3(x1)
    lw    x3, 0(x1)
    CHECK x3, 0x44332211
    li    TESTNUM, 5
    li    x2, 0x80
    sb    x2, 1(x1)
    lb    x3, 1(x1)
    CHECK x3, 0xffffff80
    lbu   x3, 1(x1)
    CHECK x3, 0x80

    li    TESTNUM, 6
    la    x1, sdat + 8              // 0xdeadbeef
    li    x2, 0x1234
    sh    x2, 2(x1)
    lw    x3, 0(x1)
    CHECK x3, 0x1234beef
    li    TESTNUM, 7
    li    x2, 0xabcd5678
    sh    x2, 0(x1)
    lw    x3, 0(x1)
    CHECK x3, 0x12345678
    lh    x3, 2(x1)
    CHECK x3, 0x1234

    li    TESTNUM, 8
    la    x1, sdat + 16
    li    x2, 0x0bad0bad
    sw    x2, -4(x1)
    lw    x3, 0(x1)
    CHECK x3, 0xdeadbeef            // neighbour untouched
    la    x4, sdat + 12
    lw    x3, 0(x4)
    CHECK x3, 0x0bad0bad

    li    TESTNUM, 9
    la    x1, sdat
    sw    x0, 0(x1)
    lw    x3, 0(x1)
    CHECK x3, 0

    // Store immediately followed by loads of the same and overlapping bytes.
    li    TESTNUM, 10
    la    x1, sdat
    li    x2, 0xcafef00d
    sw    x2, 0(x1)
    lhu   x3, 2(x1)
    CHECK x3, 0xcafe
    li    x2, 0x5a
    sb    x2, 2(x1)
    lw    x3, 0(x1)
    CHECK x3, 0xca5af00d

    // GPIO OUT: 16-bit register, byte-lane masked sub-word stores, SET/CLR.
    li    TESTNUM, 11
    li    x1, GPIO_BASE
    li    x2, 0x1234abcd
    sw    x2, 0(x1)
    lw    x3, 0(x1)
    CHECK x3, 0xabcd
    li    TESTNUM, 12
    li    x2, 0x55
    sb    x2, 1(x1)                 // lane 1 only
    lw    x3, 0(x1)
    CHECK x3, 0x55cd
    li    TESTNUM, 13
    li    x2, 0x0f00
    sw    x2, 8(x1)                 // OUT_SET
    lw    x3, 0(x1)
    CHECK x3, 0x5fcd
    li    x2, 0x00cd
    sw    x2, 12(x1)                // OUT_CLR
    lw    x3, 0(x1)
    CHECK x3, 0x5f00
    sw    x0, 0(x1)

    // TIMER MTIMECMP_LO read/write, then back to all-ones.
    li    TESTNUM, 14
    li    x1, TIMER_BASE
    li    x2, 0x12345678
    sw    x2, 8(x1)
    lw    x3, 8(x1)
    CHECK x3, 0x12345678
    li    x2, 0x9a
    sb    x2, 9(x1)
    lw    x3, 8(x1)
    CHECK x3, 0x12349a78
    li    x2, -1
    sw    x2, 8(x1)

    // Unmapped region: write dropped, reads 0.
    li    TESTNUM, 15
    li    x1, 0x30000000
    li    x2, 0x12345678
    sw    x2, 0(x1)
    lw    x3, 0(x1)
    CHECK x3, 0
    j     pass
TEST_END

    .data
    .balign 4
sdat:
    .word 0xdeadbeef, 0xdeadbeef, 0xdeadbeef, 0xdeadbeef, 0xdeadbeef, 0xdeadbeef
