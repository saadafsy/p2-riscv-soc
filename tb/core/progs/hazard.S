// Data and control hazards: every forwarding path, load-use, branch after
// load, store data after load, write-through in ID.
#include "common.h"
START
  li s0, DATA
  li t0, 0x55
  sw t0, 0(s0)
  la t0, target
  sw t0, 4(s0)
  addi t1, s0, 8
  sw t1, 8(s0)       // pointer to itself

  // EX/MEM -> EX on both operands
  TEST(1); li a0, 7; add a1, a0, a0; CHECK(a1, 14)
  // MEM/WB -> EX
  TEST(2); li a0, 9; nop; add a1, x0, a0; CHECK(a1, 9)
  TEST(3); li a0, 9; nop; add a1, a0, x0; CHECK(a1, 9)
  // rs1 from MEM/WB, rs2 from EX/MEM at the same time
  TEST(4); li a0, 3; li a2, 4; sub a1, a0, a2; CHECK(a1, -1)
  // the younger producer wins
  TEST(5); li a0, 1; li a0, 2; add a1, a0, x0; CHECK(a1, 2)
  TEST(6); li a0, 1; li a0, 2; nop; add a1, a0, x0; CHECK(a1, 2)
  // write-through: producer in WB while consumer is in ID
  TEST(7); li a0, 11; nop; nop; add a1, a0, x0; CHECK(a1, 11)
  // writes to x0 are never forwarded
  TEST(8); addi x0, x0, 1; add a1, x0, x0; CHECK(a1, 0)
  TEST(9); addi x0, x0, 1; nop; add a1, x0, x0; CHECK(a1, 0)
  // dependency chain
  TEST(10)
  li a0, 1
  add a0, a0, a0
  add a0, a0, a0
  add a0, a0, a0
  add a0, a0, a0
  CHECK(a0, 16)

  // load-use on rs1, rs2 and both
  TEST(11); lw a0, 0(s0); addi a1, a0, 1;  CHECK(a1, 0x56)
  TEST(12); lw a0, 0(s0); add a1, x0, a0;  CHECK(a1, 0x55)
  TEST(13); lw a0, 0(s0); add a1, a0, a0;  CHECK(a1, 0xAA)
  // load, one gap, use (MEM/WB forward of load data)
  TEST(14); lw a0, 0(s0); nop; add a1, a0, x0; CHECK(a1, 0x55)
  // load feeding a load address (pointer chase)
  TEST(15); lw a0, 8(s0); lw a1, 0(a0); lw a2, 0(a1); CHECK(a2, DATA+8)
  // load feeding store data and store address
  TEST(16); lw a0, 0(s0); sw a0, 12(s0); lw a1, 12(s0); CHECK(a1, 0x55)
  TEST(17); lw a0, 8(s0); sw s0, 4(a0); lw a1, 12(s0); CHECK(a1, DATA)
  // store then load the same address back to back
  TEST(18); li a0, 0x77; sw a0, 16(s0); lw a1, 16(s0); CHECK(a1, 0x77)
  // branch right after a load it depends on
  TEST(19); lw a0, 0(s0); li a1, 0x55; beq a0, a1, 1f; j fail
1: lw a0, 0(s0); bne a0, zero, 2f; j fail
2:
  // jalr through a freshly loaded pointer
  TEST(20); lw a0, 4(s0); jalr ra, 0(a0); j 3f
target:
  li a1, 0x99
  ret
3: CHECK(a1, 0x99)
  // branch on a forwarded ALU result (EX/MEM) and on MEM/WB
  TEST(21); li a0, 5; addi a0, a0, -5; beqz a0, 4f; j fail
4: li a0, 6; nop; bnez a0, 5f; j fail
5:
  // load-use where the consumer is a branch target's first instruction
  TEST(22)
  lw a0, 0(s0)
  j 6f
6: addi a1, a0, 0
  CHECK(a1, 0x55)
  // CSR result forwarded to the next instruction
  TEST(23); li a0, 0x123; csrw mscratch, a0; csrr a1, mscratch; addi a2, a1, 1
  CHECK(a2, 0x124)
END_TESTS
