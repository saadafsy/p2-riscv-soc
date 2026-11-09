// Register-register and register-immediate ALU instructions, LUI, AUIPC.
#include "common.h"
START
  li s0, 0x12345678
  li s1, 0xF0F0F0F0
  li s2, -5
  li s3, 3

  TEST(1);  add  a0, s0, s1;   CHECK(a0, 0x03254768)
  TEST(2);  sub  a0, s0, s1;   CHECK(a0, 0x21436588)
  TEST(3);  and  a0, s0, s1;   CHECK(a0, 0x10305070)
  TEST(4);  or   a0, s0, s1;   CHECK(a0, 0xF2F4F6F8)
  TEST(5);  xor  a0, s0, s1;   CHECK(a0, 0xE2C4A688)
  TEST(6);  sll  a0, s0, s3;   CHECK(a0, 0x91A2B3C0)
  TEST(7);  srl  a0, s1, s3;   CHECK(a0, 0x1E1E1E1E)
  TEST(8);  sra  a0, s1, s3;   CHECK(a0, 0xFE1E1E1E)
  TEST(9);  slt  a0, s2, s3;   CHECK(a0, 1)
  TEST(10); slt  a0, s3, s2;   CHECK(a0, 0)
  TEST(11); sltu a0, s2, s3;   CHECK(a0, 0)
  TEST(12); sltu a0, s3, s2;   CHECK(a0, 1)
  // shift amount uses only rs2[4:0]
  TEST(13); li t0, 0x21; sll a0, s3, t0; CHECK(a0, 6)
  TEST(14); li t0, 31; sra a0, s1, t0;   CHECK(a0, -1)
  TEST(15); srl a0, s1, t0;              CHECK(a0, 1)

  TEST(20); addi  a0, s0, -1;    CHECK(a0, 0x12345677)
  TEST(21); addi  a0, x0, 2047;  CHECK(a0, 2047)
  TEST(22); addi  a0, x0, -2048; CHECK(a0, -2048)
  TEST(23); andi  a0, s1, 0x7F0; CHECK(a0, 0x000000F0)
  TEST(24); ori   a0, s0, -16;   CHECK(a0, 0xFFFFFFF8)
  TEST(25); xori  a0, s0, -1;    CHECK(a0, 0xEDCBA987)
  TEST(26); slti  a0, s2, -4;    CHECK(a0, 1)
  TEST(27); slti  a0, s2, -5;    CHECK(a0, 0)
  TEST(28); sltiu a0, s3, -1;    CHECK(a0, 1)
  TEST(29); sltiu a0, s2, 3;     CHECK(a0, 0)
  TEST(30); slli  a0, s0, 4;     CHECK(a0, 0x23456780)
  TEST(31); srli  a0, s1, 4;     CHECK(a0, 0x0F0F0F0F)
  TEST(32); srai  a0, s1, 4;     CHECK(a0, 0xFF0F0F0F)
  TEST(33); srai  a0, s0, 31;    CHECK(a0, 0)
  TEST(34); slli  a0, s3, 31;    CHECK(a0, 0x80000000)

  TEST(40); lui a0, 0xABCDE;     CHECK(a0, 0xABCDE000)
  TEST(41); lui a0, 0;           CHECK(a0, 0)
  TEST(42); auipc a0, 0; auipc a1, 1; sub a2, a1, a0; CHECK(a2, 0x1004)
  TEST(43)
1: auipc a0, 0
  la a1, 1b
  bne a0, a1, fail
  // writes to x0 are discarded
  TEST(44); addi x0, x0, 5; lui x0, 0x1; add a0, x0, x0; CHECK(a0, 0)
  // overflow wraps
  TEST(45); li t0, 0x7FFFFFFF; addi a0, t0, 1; CHECK(a0, 0x80000000)
  TEST(46); li t0, 0x80000000; sub a0, x0, t0; CHECK(a0, 0x80000000)
  // FENCE and WFI are no-ops
  TEST(47); li a0, 9; fence; wfi; fence rw, rw; CHECK(a0, 9)
END_TESTS
