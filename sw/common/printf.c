#include "printf.h"

#include <stdarg.h>
#include <stdint.h>

#include "soc.h"
#include "uart.h"

void putchar_uart(char c) { uart_putc(c); }
void putchar_sim(char c) { sim_putc(c); }
void putchar_both(char c) {
  uart_putc(c);
  sim_putc(c);
}

void (*printf_putchar)(char c) = putchar_both;

static int emit_num(uint32_t v, unsigned base, int upper, int neg, int width, char pad) {
  char buf[12];
  int n = 0, out = 0;
  const char *digits = upper ? "0123456789ABCDEF" : "0123456789abcdef";
  do {
    buf[n++] = digits[v % base];
    v /= base;
  } while (v);
  int len = n + neg;
  if (neg && pad == '0') {
    printf_putchar('-');
    out++;
    neg = 0;
  }
  for (; len < width; len++, out++) printf_putchar(pad);
  if (neg) {
    printf_putchar('-');
    out++;
  }
  while (n) {
    printf_putchar(buf[--n]);
    out++;
  }
  return out;
}

int printf(const char *fmt, ...) {
  va_list ap;
  int out = 0;
  va_start(ap, fmt);
  for (; *fmt; fmt++) {
    if (*fmt != '%') {
      printf_putchar(*fmt);
      out++;
      continue;
    }
    char pad = ' ';
    int width = 0;
    fmt++;
    if (*fmt == '0') {
      pad = '0';
      fmt++;
    }
    while (*fmt >= '0' && *fmt <= '9') width = width * 10 + (*fmt++ - '0');
    switch (*fmt) {
      case 'd':
      case 'i': {
        int32_t v = va_arg(ap, int32_t);
        out += emit_num(v < 0 ? 0u - (uint32_t)v : (uint32_t)v, 10, 0, v < 0, width, pad);
        break;
      }
      case 'u':
        out += emit_num(va_arg(ap, uint32_t), 10, 0, 0, width, pad);
        break;
      case 'x':
      case 'X':
        out += emit_num(va_arg(ap, uint32_t), 16, *fmt == 'X', 0, width, pad);
        break;
      case 'p':
        printf_putchar('0');
        printf_putchar('x');
        out += 2 + emit_num((uint32_t)(uintptr_t)va_arg(ap, void *), 16, 0, 0, 8, '0');
        break;
      case 's': {
        const char *s = va_arg(ap, const char *);
        int len = 0;
        while (s[len]) len++;
        for (; len < width; len++, out++) printf_putchar(' ');
        while (*s) {
          printf_putchar(*s++);
          out++;
        }
        break;
      }
      case 'c':
        printf_putchar((char)va_arg(ap, int));
        out++;
        break;
      case '%':
        printf_putchar('%');
        out++;
        break;
      case '\0':
        fmt--;
        break;
      default:
        printf_putchar('%');
        printf_putchar(*fmt);
        out += 2;
    }
  }
  va_end(ap);
  return out;
}

int puts(const char *s) {
  int n = 0;
  while (*s) {
    printf_putchar(*s++);
    n++;
  }
  printf_putchar('\n');
  return n + 1;
}
