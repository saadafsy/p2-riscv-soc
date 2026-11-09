// Synchronous traps: mepc/mcause/mtval, mstatus stacking, MRET return.
// The handler records state in s1..s4, counts traps in s5 and resumes at
// mepc + 4.
#include "common.h"
#define EXPECT(cause, epc_label, tval) \
  CHECK(s1, cause); la t6, epc_label; bne s2, t6, fail; CHECK(s3, tval)

START
  la t0, handler
  csrw mtvec, t0
  li s0, DATA
  li s5, 0
  li t0, 0x11111111
  sw t0, 0(s0)

  TEST(1)
e1: ecall
  EXPECT(11, e1, 0)
  TEST(2)
e2: ebreak
  EXPECT(3, e2, 0)
  TEST(3)
e3: .word 0xFFFFFFFF
  EXPECT(2, e3, 0xFFFFFFFF)
  TEST(4)
e4: .word 0x00000000
  EXPECT(2, e4, 0)
  TEST(5)                    // unknown CSR
e5: csrr t0, 0x7C0
  EXPECT(2, e5, 0x7C0022F3)
  TEST(6)                    // write to a read-only CSR
e6: csrw cycle, t0
  EXPECT(2, e6, 0xC0029073)
  TEST(7)                    // reserved encodings
e7: .word 0x40001033         // sll with funct7 = 0x20
  EXPECT(2, e7, 0x40001033)
e7b: .word 0x0000100F        // fence.i (not implemented)
  EXPECT(2, e7b, 0x0000100F)
e7c: .word 0x00200073        // uret
  EXPECT(2, e7c, 0x00200073)

  TEST(8)                    // misaligned loads
  li a0, 0x5
e8: lw a0, 1(s0)
  EXPECT(4, e8, DATA+1)
  CHECK(a0, 0x5)             // rd not written
e8b: lh a0, 3(s0)
  EXPECT(4, e8b, DATA+3)
  lh a0, 2(s0)               // aligned halfword is fine
  CHECK(a0, 0x1111)
  TEST(9)                    // misaligned stores leave memory unchanged
  li t0, -1
e9: sw t0, 2(s0)
  EXPECT(6, e9, DATA+2)
e9b: sh t0, 1(s0)
  EXPECT(6, e9b, DATA+1)
  lw a0, 0(s0)
  CHECK(a0, 0x11111111)

  TEST(10)                   // misaligned jump targets
  la t0, 1f
  addi t0, t0, 2
  li ra, 0x33
e10: jalr ra, 0(t0)
  CHECK(s1, 0)
  la t6, e10
  bne s2, t6, fail
  la t6, 1f
  addi t6, t6, 2
  bne s3, t6, fail
  CHECK(ra, 0x33)            // link not written
  j 2f
1: j fail
2:
  TEST(11)
e11: .word 0x006000EF        // jal ra, .+6
  la t6, e11
  bne s2, t6, fail
  addi t6, t6, 6
  bne s3, t6, fail
  CHECK(s1, 0)
  CHECK(ra, 0x33)
  TEST(12)
e12: .word 0x00000363        // beq x0, x0, .+6
  CHECK(s1, 0)
  la t6, e12
  bne s2, t6, fail
  addi t6, t6, 6
  bne s3, t6, fail
  TEST(13)                   // not-taken branch to a misaligned target: no trap
  mv a1, s5
  .word 0x00001363           // bne x0, x0, .+6
  bne a1, s5, fail

  TEST(14)                   // mstatus stacking and MRET restore
  csrsi mstatus, 8           // MIE = 1 (no interrupt sources enabled)
e14: ecall
  CHECK(s4, 0x1880)          // in handler: MPIE = 1, MIE = 0
  csrr a0, mstatus
  CHECK(a0, 0x1888)          // after MRET: MIE = MPIE = 1
  csrci mstatus, 8
  ecall
  CHECK(s4, 0x1800)
  csrr a0, mstatus
  CHECK(a0, 0x1880)

  TEST(15)                   // instructions behind a trap do not execute
  li a1, 0
  ecall
  addi a1, a1, 1
  addi a1, a1, 1
  CHECK(a1, 2)

  TEST(16)                   // trap right after a load-use pair
  lw a0, 0(s0)
  add a0, a0, a0
e16: ecall
  CHECK(a0, 0x22222222)
  EXPECT(11, e16, 0)
  TEST(17)
  CHECK(s5, 20)              // number of traps taken so far
END_TESTS

handler:
  csrr s1, mcause
  csrr s2, mepc
  csrr s3, mtval
  csrr s4, mstatus
  addi s5, s5, 1
  addi t4, s2, 4
  csrw mepc, t4
  mret
