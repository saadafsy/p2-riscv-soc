// Timer-interrupt demo: N periodic machine-timer interrupts, an LED step per tick.
#include "gpio.h"
#include "printf.h"
#include "soc.h"
#include "timer.h"

#define TICKS 5
#define PERIOD 2000  // mtime units (clock cycles on hardware)

static volatile uint32_t ticks;

uint32_t trap_handler(uint32_t mcause, uint32_t mepc, uint32_t mtval) {
  (void)mtval;
  if (mcause != MCAUSE_IRQ_TIMER) sim_exit(0xE0000000u | (mcause & 0xFF));
  ticks++;
  gpio_write(1u << ticks);
  if (ticks < TICKS)
    timer_arm(PERIOD);
  else
    timer_disarm();
  return mepc;  // interrupts resume at the interrupted instruction
}

int main(void) {
  printf("timer_irq: %d ticks, period %d\n", TICKS, PERIOD);
  timer_arm(PERIOD);
  irq_enable();
  uint32_t spins = 0;
  while (ticks < TICKS) {
    __asm__ volatile("wfi");
    spins++;
  }
  irq_disable();
  printf("timer_irq: got %u ticks after %u wait loops\n", ticks, spins);
  return ticks == TICKS ? 0 : 1;
}
