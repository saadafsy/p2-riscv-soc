// Machine timer interrupt through the TIMER: mip.MTIP, gating by mstatus.MIE and
// mie.MTIE, mcause/mepc, mstatus on entry and return, WFI. Loop bounds are generous so
// the test passes whether mtime counts clock cycles (RTL) or instructions (ISS).
// The handler records mcause/mepc/mstatus in x25/x26/x23, counts in x24, and
// silences the timer (mtimecmp = all-ones).
#include "isa.h"

// Spin up to \n iterations or until x24 != \count; x4 = iterations left.
.macro SPIN n, count
    li    x4, \n
1:  li    x29, \count
    bne   x24, x29, 2f
    addi  x4, x4, -1
    bnez  x4, 1b
2:
.endm

TEST_BEGIN
    la    t0, irq_handler
    csrw  mtvec, t0
    li    x24, 0
    li    x20, TIMER_BASE

    // Compare all-ones: MTIP clear.
    li    TESTNUM, 1
    csrr  x3, mip
    CHECK x3, 0

    // mtimecmp = 0: MTIP set (poll; the comparator may lag the store).
    li    TESTNUM, 2
    sw    x0, 8(x20)
    sw    x0, 12(x20)
    li    x4, 100
3:  csrr  x3, mip
    andi  x3, x3, 0x80
    bnez  x3, 4f
    addi  x4, x4, -1
    bnez  x4, 3b
    j     fail
4:
    // MTIE = 1 but mstatus.MIE = 0: no interrupt.
    li    TESTNUM, 3
    li    x1, MIE_MTIE
    csrw  mie, x1
    SPIN  200, 0
    CHECK x24, 0

    // mstatus.MIE = 1 but MTIE = 0: no interrupt.
    li    TESTNUM, 4
    csrw  mie, x0
    csrsi mstatus, 8
    SPIN  200, 0
    CHECK x24, 0
    csrr  x3, mip
    CHECK x3, 0x80                  // still pending

    // Both enabled: taken within the spin loop.
    li    TESTNUM, 5
    li    x1, MIE_MTIE
spin5_start:
    csrs  mie, x1
    SPIN  200, 0
spin5_end:
    CHECK x24, 1
    beqz  x4, fail
    li    x29, MCAUSE_IRQ_TIMER
    bne   x25, x29, fail
    la    x29, spin5_start
    bltu  x26, x29, fail
    la    x29, spin5_end
    bgeu  x26, x29, fail
    CHECK x23, 0x1880               // in handler: MIE = 0, MPIE = 1
    csrr  x3, mstatus
    CHECK x3, 0x1888                // after mret: MIE restored

    // Handler silenced the timer: no second interrupt.
    li    TESTNUM, 6
    SPIN  200, 1
    CHECK x24, 1
    csrr  x3, mip
    CHECK x3, 0

    // Arm mtimecmp = mtime + 300: not immediate, but arrives.
    li    TESTNUM, 7
    csrci mstatus, 8
    lw    x1, 0(x20)                // mtime_lo
    lw    x2, 4(x20)                // mtime_hi
    addi  x3, x1, 300
    sltu  x5, x3, x1                // carry
    add   x2, x2, x5
    li    x5, -1
    sw    x5, 12(x20)
    sw    x3, 8(x20)
    sw    x2, 12(x20)
    lw    x5, 12(x20)               // store has completed
    csrsi mstatus, 8
    li    x6, 0
5:  li    x29, 1
    bne   x24, x29, 6f
    addi  x6, x6, 1
    li    x29, 100000
    bltu  x6, x29, 5b
    j     fail
6:  CHECK x24, 2
    beqz  x6, fail                  // at least one iteration before the interrupt

    // WFI (a no-op here) in a wait loop.
    li    TESTNUM, 8
    csrci mstatus, 8
    lw    x1, 0(x20)
    lw    x2, 4(x20)
    addi  x3, x1, 100
    sltu  x5, x3, x1
    add   x2, x2, x5
    li    x5, -1
    sw    x5, 12(x20)
    sw    x3, 8(x20)
    sw    x2, 12(x20)
    csrsi mstatus, 8
    li    x6, 100000
7:  wfi
    li    x29, 2
    bne   x24, x29, 8f
    addi  x6, x6, -1
    bnez  x6, 7b
    j     fail
8:  CHECK x24, 3
    csrci mstatus, 8
    csrw  mie, x0
    j     pass

    .balign 4
irq_handler:
    csrr  x25, mcause
    csrr  x26, mepc
    csrr  x23, mstatus
    addi  x24, x24, 1
    li    x22, -1
    sw    x22, 12(x20)
    sw    x22, 8(x20)
    lw    x22, 8(x20)               // store has completed before mret
    mret
TEST_END
