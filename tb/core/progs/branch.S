// Conditional branches (taken and not taken), JAL/JALR link values,
// back-to-back control transfers.
#include "common.h"
#define TAKEN(insn, a, b)     insn a, b, 1f; j fail; 1:
#define NOT_TAKEN(insn, a, b) insn a, b, fail

START
  li s0, 5
  li s1, -3
  li s2, 5

  TEST(1);  TAKEN(beq, s0, s2)
  TEST(2);  NOT_TAKEN(beq, s0, s1)
  TEST(3);  TAKEN(bne, s0, s1)
  TEST(4);  NOT_TAKEN(bne, s0, s2)
  TEST(5);  TAKEN(blt, s1, s0)
  TEST(6);  NOT_TAKEN(blt, s0, s1)
  TEST(7);  NOT_TAKEN(blt, s0, s2)
  TEST(8);  TAKEN(bge, s0, s1)
  TEST(9);  TAKEN(bge, s0, s2)
  TEST(10); NOT_TAKEN(bge, s1, s0)
  TEST(11); TAKEN(bltu, s0, s1)
  TEST(12); NOT_TAKEN(bltu, s1, s0)
  TEST(13); TAKEN(bgeu, s1, s0)
  TEST(14); NOT_TAKEN(bgeu, s0, s1)
  TEST(15); TAKEN(bgeu, s0, s2)

  // JAL writes pc+4 and jumps
  TEST(20)
  jal ra, 2f
3: j fail
2: la t0, 3b
  bne ra, t0, fail

  // JALR: target = (rs1 + imm) & ~1, link = pc+4, rd == rs1
  TEST(21)
  la t0, 4f
  addi t0, t0, -7
  jalr t1, 8(t0)          // (4f - 7 + 8) & ~1 = 4f
5: j fail
  .balign 4
4: la t2, 5b
  bne t1, t2, fail
  TEST(22)
  la t0, 6f
  jalr t0, 0(t0)          // link overwrites the base register
7: j fail
6: la t2, 7b
  bne t0, t2, fail

  // back-to-back control transfers: every second instruction is wrong-path
  TEST(23)
  li a0, 0
  beq x0, x0, 8f
  addi a0, a0, 1
8: bne x0, x0, fail
  bne x0, x0, fail
  beq x0, x0, 9f
  addi a0, a0, 1
9: jal x0, 10f
  addi a0, a0, 1
10: j 11f
  addi a0, a0, 1
11: bnez a0, fail

  // backward loop branch
  TEST(24)
  li a0, 0
  li a1, 10
12: addi a0, a0, 3
  addi a1, a1, -1
  bnez a1, 12b
  CHECK(a0, 30)

  // call / return
  TEST(25)
  li a0, 4
  call func
  CHECK(a0, 8)
  j 13f
func:
  add a0, a0, a0
  ret
13:
END_TESTS
