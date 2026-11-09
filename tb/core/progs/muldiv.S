// M extension in the pipeline: load-use into M, M into M, M into branch, jalr,
// store data and address, M behind a trap (flushed while in flight), M in the
// shadow of a taken branch, M results under random memory latency.
#include "common.h"
START
  la t0, handler
  csrw mtvec, t0
  li s0, DATA
  li s9, 0                   // traps taken
  li t0, 12
  sw t0, 0(s0)
  li t0, -5
  sw t0, 4(s0)

  TEST(1)                    // load-use into both operands
  lw a0, 0(s0)
  mul a1, a0, a0
  CHECK(a1, 144)
  lw a0, 4(s0)
  div a1, a0, a0
  CHECK(a1, 1)
  lw a0, 0(s0)
  lw a2, 4(s0)
  rem a1, a0, a2             // 12 % -5 = 2
  CHECK(a1, 2)

  TEST(2)                    // M result straight into the next M, both operands
  li a0, 3
  mul a1, a0, a0
  mul a1, a1, a1
  divu a1, a1, a0
  remu a2, a1, a0
  mulhu a3, a1, a1
  CHECK(a1, 27)
  CHECK(a2, 0)
  CHECK(a3, 0)

  TEST(3)                    // M result into a branch, an address and store data
  li a0, 6
  li a1, 7
  mul a2, a0, a1
  li t0, 42
  bne a2, t0, fail
  li a3, 2
  div a4, s0, a3             // DATA / 2
  add a4, a4, a4
  mul a5, a0, a1
  sw a5, 8(a4)               // store data and address from M results
  lw t1, 8(s0)
  CHECK(t1, 42)

  TEST(4)                    // jalr through an M result
  la a0, tgt4
  li a1, 1
  mul a2, a0, a1
  jalr ra, 0(a2)
  j 1f
tgt4:
  li a3, 0x44
  ret
1: CHECK(a3, 0x44)

  TEST(5)                    // a divide right behind a trap is flushed, then re-run
  li a0, 100
  li a1, 7
  ecall
  div a2, a0, a1
  CHECK(a2, 14)
  CHECK(s9, 1)
  lh t0, 1(s0)               // misaligned load trap, divide behind it
  rem a2, a0, a1
  CHECK(a2, 2)
  CHECK(s9, 2)

  TEST(6)                    // M ops in the shadow of a taken jump never execute
  li a2, 5
  j 2f
  div a2, a2, x0
  mul a2, a2, a2
2: CHECK(a2, 5)

  TEST(7)                    // M with rd = x0, and the dividend-by-zero results
  mul x0, a0, a1
  div x0, a0, x0
  CHECK(x0, 0)
  li a0, -9
  div a1, a0, x0
  rem a2, a0, x0
  CHECK(a1, -1)
  CHECK(a2, -9)
  li a0, 0x80000000
  li a3, -1
  div a1, a0, a3
  rem a2, a0, a3
  CHECK(a1, 0x80000000)
  CHECK(a2, 0)

  TEST(8)                    // CSR read right after M: minstret counts M ops once
  csrr t1, minstret
  mul a0, a0, a0
  div a0, a0, a3
  csrr t2, minstret
  sub t2, t2, t1
  CHECK(t2, 3)
END_TESTS

handler:                     // skip the trapping instruction
  addi s9, s9, 1
  csrr t0, mepc
  addi t0, t0, 4
  csrw mepc, t0
  mret
