// Stress: random interrupt pulses (testbench irq_noise) over a loop of divides,
// remainders and multiplies with loads and stores in between. Each interrupt that
// lands on an M instruction restarts it; the checksum must still come out right.
#include "common.h"
START
  la t0, handler
  csrw mtvec, t0
  li t0, 0x880
  csrw mie, t0
  csrsi mstatus, 8
  li s11, 0                  // interrupts taken
  li s0, DATA
  li a0, 0                   // checksum
  li a1, 40                  // i
  li a5, 12345
loop:
  mul a2, a1, a5
  addi a2, a2, 7             // a = i * 12345 + 7
  sw a2, 0(s0)
  addi a3, a1, 1             // d = i + 1
  lw a4, 0(s0)
  div t1, a4, a3
  rem t2, a4, a3
  xor t1, t1, t2
  add a0, a0, t1
  mulhu t3, a4, a4
  add a0, a0, t3
  neg a4, a4
  div t1, a4, a3
  add a0, a0, t1
  addi a1, a1, -1
  bnez a1, loop
  TEST(1)
  CHECK(a0, 0x30f)
  csrci mstatus, 8
END_TESTS

handler:
  addi s11, s11, 1
  mret
