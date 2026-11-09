#ifndef UART_H
#define UART_H
#include <stdint.h>

void uart_set_divisor(uint32_t cycles_per_bit);
void uart_putc(char c);
void uart_puts(const char *s);
// Returns the received byte, or -1 if the RX FIFO is empty.
int uart_getc(void);

#endif
