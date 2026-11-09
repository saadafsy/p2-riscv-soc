#include "gpio.h"
#include "soc.h"

void gpio_write(uint32_t leds) { REG32(GPIO_OUT) = leds & 0xFFFF; }
void gpio_set(uint32_t mask) { REG32(GPIO_OUT_SET) = mask & 0xFFFF; }
void gpio_clear(uint32_t mask) { REG32(GPIO_OUT_CLR) = mask & 0xFFFF; }
uint32_t gpio_leds(void) { return REG32(GPIO_OUT); }
uint32_t gpio_read(void) { return REG32(GPIO_IN); }
