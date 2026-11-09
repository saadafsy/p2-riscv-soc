#ifndef TIMER_H
#define TIMER_H
#include <stdint.h>

uint64_t timer_now(void);
void timer_set_cmp(uint64_t cmp);
// mtimecmp = now + delta and enable the machine timer interrupt (mie.MTIE).
void timer_arm(uint32_t delta);
// mtimecmp = all-ones (deasserts irq_timer) and clear mie.MTIE.
void timer_disarm(void);
static inline void irq_enable(void) { __asm__ volatile("csrsi mstatus, 8"); }
static inline void irq_disable(void) { __asm__ volatile("csrci mstatus, 8"); }

#endif
