// CSR read/write/set/clear (register and immediate forms) and CSR field rules.
#include "common.h"
START
  TEST(1); li t0, 0xA5A5A5A5; csrw mscratch, t0; csrr a0, mscratch; CHECK(a0, 0xA5A5A5A5)
  TEST(2); li t0, 0x0000FFFF; csrrs a0, mscratch, t0; CHECK(a0, 0xA5A5A5A5)
  csrr a0, mscratch; CHECK(a0, 0xA5A5FFFF)
  TEST(3); li t0, 0xFF0000FF; csrrc a0, mscratch, t0; CHECK(a0, 0xA5A5FFFF)
  csrr a0, mscratch; CHECK(a0, 0x00A5FF00)
  TEST(4); li t0, 0x42; csrrw a0, mscratch, t0; CHECK(a0, 0x00A5FF00)
  csrr a0, mscratch; CHECK(a0, 0x42)
  TEST(5); csrrwi a0, mscratch, 0x15; CHECK(a0, 0x42)
  csrr a0, mscratch; CHECK(a0, 0x15)
  TEST(6); csrrsi a0, mscratch, 0x0A; CHECK(a0, 0x15)
  csrr a0, mscratch; CHECK(a0, 0x1F)
  TEST(7); csrrci a0, mscratch, 0x03; CHECK(a0, 0x1F)
  csrr a0, mscratch; CHECK(a0, 0x1C)
  // rd = x0 still writes; rs1 = x0 set/clear does not write
  TEST(8); li t0, 0x77; csrrw x0, mscratch, t0; csrrs a0, mscratch, x0; CHECK(a0, 0x77)
  csrrc a0, mscratch, x0; CHECK(a0, 0x77)

  // field rules
  TEST(10); li t0, 0x1003; csrw mtvec, t0; csrr a0, mtvec; CHECK(a0, 0x1000)
  TEST(11); li t0, 0x1237; csrw mepc, t0;  csrr a0, mepc;  CHECK(a0, 0x1234)
  TEST(12); csrr a0, misa; CHECK(a0, 0x40000100)
  li t0, -1; csrw misa, t0; csrr a0, misa; CHECK(a0, 0x40000100)
  TEST(13); csrr a0, mhartid; CHECK(a0, 0)
  csrr a0, mvendorid; CHECK(a0, 0)
  csrr a0, marchid; CHECK(a0, 0)
  csrr a0, mimpid; CHECK(a0, 0)
  TEST(14); csrr a0, mstatus; CHECK(a0, 0x1800)
  li t0, -1; csrw mstatus, t0; csrr a0, mstatus; CHECK(a0, 0x1888)
  csrw mstatus, zero; csrr a0, mstatus; CHECK(a0, 0x1800)
  TEST(15); li t0, -1; csrw mie, t0; csrr a0, mie; CHECK(a0, 0x880)
  csrw mie, zero
  TEST(16); csrr a0, mip; CHECK(a0, 0)
  li t0, -1; csrw mip, t0; csrr a0, mip; CHECK(a0, 0)
  TEST(17); li t0, 0x8000000B; csrw mcause, t0; csrr a0, mcause; CHECK(a0, 0x8000000B)
  li t0, 0x13579BDF; csrw mtval, t0; csrr a0, mtval; CHECK(a0, 0x13579BDF)

  // counters: a write wins over the writer's own increment
  TEST(20); li t0, 100; csrw minstret, t0; csrr a0, minstret; CHECK(a0, 100)
  csrr a0, minstret; CHECK(a0, 103)
  TEST(21); csrr a0, minstret; csrr a1, instret; sub a2, a1, a0; CHECK(a2, 1)
  TEST(22); li t0, -2; csrw minstret, t0; csrw minstreth, zero; nop; nop
  csrr a0, minstreth; CHECK(a0, 1)
  TEST(23); csrr a0, instreth; CHECK(a0, 1)
  TEST(24); csrr a0, mcycle; nop; nop; csrr a1, mcycle; sub a2, a1, a0
  bgeu x0, a2, fail       // mcycle advanced
  csrr a0, cycle; csrr a1, mcycle; bltu a1, a0, fail
  TEST(25); li t0, 0x1000; csrw mcycle, t0; csrr a0, mcycle
  li t0, 0x1000; bltu a0, t0, fail
  li t0, 0x1100; bgeu a0, t0, fail
  TEST(26); csrw mcycleh, zero; csrr a0, mcycleh; csrr a1, cycleh; CHECK(a1, 0)
  // read-only CSRs can be read with set/clear of x0
  TEST(27); csrrs a0, cycle, x0; csrrc a1, mhartid, x0; CHECK(a1, 0)
END_TESTS
