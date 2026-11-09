#ifndef GPIO_H
#define GPIO_H
#include <stdint.h>

void gpio_write(uint32_t leds);
void gpio_set(uint32_t mask);
void gpio_clear(uint32_t mask);
uint32_t gpio_leds(void);
uint32_t gpio_read(void);  // 15:0 switches, 20:16 buttons

#endif
