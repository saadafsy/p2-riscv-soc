// Interrupts while an M instruction is in EX: the operation is abandoned, mepc is
// the M instruction, and it executes again after MRET with the right result.
// SIM_IRQ bit0 drives irq_timer, bit1 irq_external (see irq.S).
#include "common.h"
#define RAISE(bits) li s7, bits; sw s7, 0(s8)

START
  la t0, handler
  csrw mtvec, t0
  li s5, 0                   // interrupts taken
  li s7, 0
  li s8, SIM_IRQ
  li t0, 0x880
  csrw mie, t0
  csrsi mstatus, 8

  TEST(1)                    // timer interrupt during a divide
  li a0, 1000
  li a1, 7
  RAISE(1)
d1: div a2, a0, a1
  CHECK(a2, 142)
  CHECK(s5, 1)
  la t6, d1
  bne s2, t6, fail

  TEST(2)                    // external interrupt during a remainder whose operand came from a load
  li t0, DATA
  sw a0, 0(t0)
  RAISE(2)
  lw a3, 0(t0)
d2: remu a2, a3, a1
  CHECK(a2, 6)
  CHECK(s5, 2)
  la t6, d2
  bne s2, t6, fail

  TEST(3)                    // interrupt during a multiply chain
  li a0, 3
  RAISE(1)
  mul a2, a0, a0
  mul a2, a2, a2
  mulh a3, a2, a2
  CHECK(a2, 81)
  CHECK(a3, 0)
  CHECK(s5, 3)

  TEST(4)                    // both lines during back-to-back divides
  li a0, -1000
  li a1, 9
  RAISE(3)
  div a2, a0, a1
  rem a3, a0, a1
  div a4, a2, a1
  CHECK(a2, -111)
  CHECK(a3, -1)
  CHECK(a4, -12)
  CHECK(s5, 5)
  csrci mstatus, 8
END_TESTS

handler:
  csrr s1, mcause
  csrr s2, mepc
  bgez s1, fail              // no synchronous traps expected
  addi s5, s5, 1
  andi t3, s1, 0xF
  li t4, 11
  beq t3, t4, 1f
  andi s7, s7, -2
  j 2f
1: andi s7, s7, -3
2: sw s7, 0(s8)
  mret
