#ifndef PRINTF_H
#define PRINTF_H

// printf-lite: %d %i %u %x %X %p %s %c %%, optional '0' flag and width (e.g. %08x).
// Output goes to printf_putchar (default: UART and SIMCTRL PUTC).
int printf(const char *fmt, ...);
int puts(const char *s);  // writes s and '\n'
extern void (*printf_putchar)(char c);
void putchar_both(char c);
void putchar_uart(char c);
void putchar_sim(char c);

#endif
