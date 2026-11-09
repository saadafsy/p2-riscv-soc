#include "timer.h"
#include "soc.h"

uint64_t timer_now(void) {
  uint32_t hi, lo;
  do {  // re-read if the low word wrapped between the two loads
    hi = REG32(TIMER_MTIME_HI);
    lo = REG32(TIMER_MTIME_LO);
  } while (hi != REG32(TIMER_MTIME_HI));
  return ((uint64_t)hi << 32) | lo;
}

void timer_set_cmp(uint64_t cmp) {
  // Raise HI first so no spurious match happens while LO is updated.
  REG32(TIMER_MTIMECMP_HI) = 0xFFFFFFFFu;
  REG32(TIMER_MTIMECMP_LO) = (uint32_t)cmp;
  REG32(TIMER_MTIMECMP_HI) = (uint32_t)(cmp >> 32);
}

void timer_arm(uint32_t delta) {
  timer_set_cmp(timer_now() + delta);
  csr_set(mie, MIE_MTIE);
}

void timer_disarm(void) {
  csr_clear(mie, MIE_MTIE);
  REG32(TIMER_MTIMECMP_HI) = 0xFFFFFFFFu;
  REG32(TIMER_MTIMECMP_LO) = 0xFFFFFFFFu;
}
