// p2-riscv-soc register map (docs/spec.md sections 5 and 8).
#ifndef SOC_H
#define SOC_H

#define RAM_BASE      0x00000000u
#define RAM_SIZE      0x00010000u

#define UART_BASE     0x10000000u
#define GPIO_BASE     0x10001000u
#define TIMER_BASE    0x10002000u
#define SIMCTRL_BASE  0x1000F000u

#define UART_DATA     (UART_BASE + 0x0)  // W: push TX; R: pop RX, bit 8 = valid
#define UART_STATUS   (UART_BASE + 0x4)
#define UART_DIVISOR  (UART_BASE + 0x8)  // clk cycles per bit, reset 868
#define UART_IRQ_EN   (UART_BASE + 0xC)  // bit0: rx interrupt
#define UART_ST_TX_FULL    (1u << 0)
#define UART_ST_TX_EMPTY   (1u << 1)
#define UART_ST_RX_VALID   (1u << 2)
#define UART_ST_RX_OVERRUN (1u << 3)     // write 1 to clear
#define UART_RX_VALID      (1u << 8)

#define GPIO_OUT      (GPIO_BASE + 0x0)  // 16 LEDs
#define GPIO_IN       (GPIO_BASE + 0x4)  // 15:0 switches, 20:16 buttons
#define GPIO_OUT_SET  (GPIO_BASE + 0x8)
#define GPIO_OUT_CLR  (GPIO_BASE + 0xC)

#define TIMER_MTIME_LO    (TIMER_BASE + 0x0)
#define TIMER_MTIME_HI    (TIMER_BASE + 0x4)
#define TIMER_MTIMECMP_LO (TIMER_BASE + 0x8)
#define TIMER_MTIMECMP_HI (TIMER_BASE + 0xC)

#define SIMCTRL_EXIT  (SIMCTRL_BASE + 0x0)  // W: end simulation, code = value
#define SIMCTRL_PUTC  (SIMCTRL_BASE + 0x4)  // W: print low byte

#define MSTATUS_MIE   (1u << 3)
#define MSTATUS_MPIE  (1u << 7)
#define MIE_MTIE      (1u << 7)
#define MIE_MEIE      (1u << 11)
#define MCAUSE_IRQ_TIMER 0x80000007u
#define MCAUSE_IRQ_EXT   0x8000000Bu

#ifndef __ASSEMBLER__
#include <stdint.h>

#define REG32(a) (*(volatile uint32_t *)(uintptr_t)(a))

#define csr_read(csr) ({ uint32_t v_; __asm__ volatile("csrr %0, " #csr : "=r"(v_)); v_; })
#define csr_write(csr, v) __asm__ volatile("csrw " #csr ", %0" ::"r"((uint32_t)(v)))
#define csr_set(csr, v) __asm__ volatile("csrs " #csr ", %0" ::"r"((uint32_t)(v)))
#define csr_clear(csr, v) __asm__ volatile("csrc " #csr ", %0" ::"r"((uint32_t)(v)))

static inline void sim_exit(uint32_t code) {
  REG32(SIMCTRL_EXIT) = code;
  for (;;) {
  }
}
static inline void sim_putc(char c) { REG32(SIMCTRL_PUTC) = (uint8_t)c; }

// Called by crt0's trap entry with all caller-saved registers preserved.
// Returns the pc to resume at (written to mepc before mret). Weak default exits.
uint32_t trap_handler(uint32_t mcause, uint32_t mepc, uint32_t mtval);
#endif

#endif
