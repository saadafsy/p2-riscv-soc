// Timing kernels measured by test_cpi from the RVFI retirement cycles:
//   cpi_*: dependent ALU chain (forwarding every instruction), expect CPI 1
//   lu_*:  load followed by its consumer, expect 1 stall per pair
//   br_*:  taken jumps, expect 2 bubbles each
//   mul_*, div_*: dependent M chains, expect 4 and 34 cycles each
#include "common.h"
  .globl cpi_start, cpi_end, lu_start, lu_end, br_start, br_end
  .globl mul_start, mul_end, div_start, div_end
START
  li s0, DATA
  li a0, 0
  li a1, 1
cpi_start:
  .rept 100
  addi a0, a0, 1
  xor a1, a1, a0
  .endr
cpi_end:
  nop
lu_start:
  .rept 20
  lw a2, 0(s0)
  add a3, a2, a2
  .endr
lu_end:
  nop
br_start:
  .rept 20
  j 1f
1:
  .endr
br_end:
  nop
  li a4, 3
mul_start:
  .rept 20
  mul a5, a5, a4             // dependent chain
  .endr
mul_end:
  nop
  li a5, -1
div_start:
  .rept 10
  divu a5, a5, a4            // dependent chain
  .endr
div_end:
  nop
  TEST(1)
  CHECK(a0, 100)
END_TESTS
