// Timer and external interrupts: mstatus.MIE and mie gating, priority,
// mepc = next unretired instruction. The testbench maps SIM_IRQ bit0 to
// irq_timer and bit1 to irq_external; s7 shadows those bits.
#include "common.h"
#define RAISE(bits) li s7, bits; sw s7, 0(s8)
#define NOPS nop; nop; nop; nop; nop; nop

START
  la t0, handler
  csrw mtvec, t0
  li s5, 0                   // interrupts taken
  li s6, DATA                // cause log
  li s7, 0
  li s8, SIM_IRQ

  TEST(1)                    // MIE = 0 masks everything
  li t0, 0x80
  csrw mie, t0
  RAISE(1)
  NOPS
  CHECK(s5, 0)
  csrr a0, mip
  CHECK(a0, 0x80)

  TEST(2)                    // enabling MIE takes it before the next instruction
  csrsi mstatus, 8
i2: nop
  CHECK(s5, 1)
  CHECK(s1, 0x80000007)
  la t6, i2
  bne s2, t6, fail
  csrr a0, mip
  CHECK(a0, 0)
  csrr a0, mstatus
  CHECK(a0, 0x1888)

  TEST(3)                    // mie gating: external pending but MEIE = 0
  RAISE(2)
  NOPS
  CHECK(s5, 1)
  csrr a0, mip
  CHECK(a0, 0x800)
  li t0, 0x800
  csrs mie, t0
i3: nop
  CHECK(s5, 2)
  CHECK(s1, 0x8000000B)
  la t6, i3
  bne s2, t6, fail

  TEST(4)                    // both pending: external first, then timer
  csrci mstatus, 8
  RAISE(3)
  NOPS
  CHECK(s5, 2)
  li s6, DATA
  csrsi mstatus, 8
i4: nop
  CHECK(s5, 4)
  li t0, DATA
  lw a0, 0(t0)
  CHECK(a0, 0x8000000B)
  lw a0, 4(t0)
  CHECK(a0, 0x80000007)
  la t6, i4
  bne s2, t6, fail

  TEST(5)                    // interrupt inside straight-line work is precise
  li a0, 0
  RAISE(1)
  addi a0, a0, 1
  addi a0, a0, 1
  addi a0, a0, 1
  addi a0, a0, 1
  addi a0, a0, 1
  addi a0, a0, 1
  CHECK(a0, 6)
  CHECK(s5, 5)

  TEST(6)                    // interrupt around a load-use pair, a store and a branch
  li t1, DATA+64
  li t2, 21
  sw t2, 0(t1)
  RAISE(2)
  lw a0, 0(t1)
  add a0, a0, a0
  sw a0, 4(t1)
  beq a0, a0, 1f
  j fail
1: lw a1, 4(t1)
  CHECK(a1, 42)
  CHECK(s5, 6)

  TEST(7)                    // WFI is a no-op; the interrupt still arrives
  RAISE(1)
  wfi
  nop
  nop
  CHECK(s5, 7)

  TEST(9)                    // an interrupted CSR swap has no effect until re-executed
  csrci mstatus, 8
  li t0, 1
  csrw mscratch, t0
  li a5, 2
  RAISE(1)
  csrsi mstatus, 8
i9: csrrw a5, mscratch, a5   // first instruction after the serializing enable
  CHECK(a5, 1)
  csrr a0, mscratch
  CHECK(a0, 2)
  la t6, i9
  bne s2, t6, fail
  CHECK(s5, 8)

  TEST(8)                    // clearing mie disables again
  csrw mie, zero
  RAISE(3)
  NOPS
  CHECK(s5, 8)
  li s7, 0
  sw s7, 0(s8)
END_TESTS

handler:
  csrr s1, mcause
  csrr s2, mepc
  bgez s1, fail              // no synchronous traps expected here
  addi s5, s5, 1
  sw s1, 0(s6)
  addi s6, s6, 4
  andi t3, s1, 0xF
  li t4, 11
  beq t3, t4, 1f
  andi s7, s7, -2            // timer: drop bit0
  j 2f
1: andi s7, s7, -3           // external: drop bit1
2: sw s7, 0(s8)
  mret
