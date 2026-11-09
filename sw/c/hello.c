// Prints a greeting on the UART and the SIMCTRL console; exits 0.
#include "gpio.h"
#include "printf.h"
#include "soc.h"

int main(void) {
  gpio_write(0x00A5);
  printf("Hello from p2-riscv-soc!\n");
  printf("misa=%08x mhartid=%u dec=%d hex=%x str=%s\n", csr_read(misa), csr_read(mhartid),
         -1234, 0xbeefu, "ok");
  return gpio_leds() == 0x00A5 ? 0 : 1;
}
