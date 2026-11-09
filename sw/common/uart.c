#include "uart.h"
#include "soc.h"

void uart_set_divisor(uint32_t cycles_per_bit) { REG32(UART_DIVISOR) = cycles_per_bit; }

void uart_putc(char c) {
  while (REG32(UART_STATUS) & UART_ST_TX_FULL) {
  }
  REG32(UART_DATA) = (uint8_t)c;
}

void uart_puts(const char *s) {
  while (*s) uart_putc(*s++);
}

int uart_getc(void) {
  uint32_t v = REG32(UART_DATA);
  return (v & UART_RX_VALID) ? (int)(v & 0xFF) : -1;
}
