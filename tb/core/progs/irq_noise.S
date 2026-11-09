// Stress: the testbench pulses irq_timer / irq_external at random while this
// loop mixes loads, stores, calls, branches and ECALLs. The lockstep model
// catches any imprecise interrupt; the program checks its own result.
#include "common.h"
START
  la t0, handler
  csrw mtvec, t0
  li t0, 0x880
  csrw mie, t0
  csrsi mstatus, 8
  li s8, 0                   // synchronous traps
  li s11, 0                  // all traps and interrupts
  li s0, DATA
  li a0, 0
  li a1, 50
loop:
  sw a1, 0(s0)
  lw a2, 0(s0)
  add a0, a0, a2
  slli a3, a2, 1
  sh a3, 4(s0)
  lhu a4, 4(s0)
  add a0, a0, a4
  call inc
  andi t0, a1, 7
  bnez t0, 1f
  ecall
1: addi a1, a1, -1
  bnez a1, loop
  TEST(1)
  CHECK(a0, 3875)
  TEST(2)
  CHECK(s8, 6)
  csrci mstatus, 8
END_TESTS

inc:
  addi a0, a0, 1
  ret

handler:
  csrr s9, mcause
  addi s11, s11, 1
  bltz s9, 1f
  csrr s10, mepc
  addi s10, s10, 4
  csrw mepc, s10
  addi s8, s8, 1
1: mret
