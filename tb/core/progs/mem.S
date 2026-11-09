// Loads and stores of every width and byte offset, sign/zero extension.
#include "common.h"
START
  li s0, DATA
  li s1, 0x8899AABB
  sw s1, 0(s0)
  sw zero, 4(s0)

  TEST(1); lw a0, 0(s0);  CHECK(a0, 0x8899AABB)
  TEST(2); lb a0, 0(s0);  CHECK(a0, 0xFFFFFFBB)
  TEST(3); lb a0, 1(s0);  CHECK(a0, 0xFFFFFFAA)
  TEST(4); lb a0, 2(s0);  CHECK(a0, 0xFFFFFF99)
  TEST(5); lb a0, 3(s0);  CHECK(a0, 0xFFFFFF88)
  TEST(6); lbu a0, 0(s0); CHECK(a0, 0xBB)
  TEST(7); lbu a0, 3(s0); CHECK(a0, 0x88)
  TEST(8); lh a0, 0(s0);  CHECK(a0, 0xFFFFAABB)
  TEST(9); lh a0, 2(s0);  CHECK(a0, 0xFFFF8899)
  TEST(10); lhu a0, 0(s0); CHECK(a0, 0xAABB)
  TEST(11); lhu a0, 2(s0); CHECK(a0, 0x8899)

  // positive values do not sign-extend
  TEST(12); li t0, 0x7F7F; sh t0, 4(s0); lh a0, 4(s0); CHECK(a0, 0x7F7F)
  TEST(13); lb a0, 4(s0); CHECK(a0, 0x7F)

  // byte stores into each lane
  TEST(14)
  sw zero, 8(s0)
  li t0, 0x11; sb t0, 8(s0)
  li t0, 0x22; sb t0, 9(s0)
  li t0, 0x33; sb t0, 10(s0)
  li t0, 0x44; sb t0, 11(s0)
  lw a0, 8(s0); CHECK(a0, 0x44332211)
  // halfword stores into each half
  TEST(15)
  li t0, 0xBEEF; sh t0, 12(s0)
  li t0, 0xDEAD; sh t0, 14(s0)
  lw a0, 12(s0); CHECK(a0, 0xDEADBEEF)
  // sub-word store keeps the other bytes
  TEST(16)
  li t0, 0x12345678; sw t0, 16(s0)
  li t0, 0xFFFFFFAB; sb t0, 17(s0)
  lw a0, 16(s0); CHECK(a0, 0x1234AB78)
  // negative offsets
  TEST(17)
  addi t1, s0, 20
  li t0, 0xCAFEF00D; sw t0, -4(t1)
  lw a0, 16(s0); CHECK(a0, 0xCAFEF00D)
  // reads outside RAM (unmapped in this testbench) return 0
  TEST(18)
  li t1, 0x20000000
  lw a0, 0(t1); CHECK(a0, 0)
END_TESTS
