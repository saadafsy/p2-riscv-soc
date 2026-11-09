// Attention accelerator driver (docs/spec.md section 12).
#include "accel.h"

#include "soc.h"

int accel_present(void) { return REG32(ACCEL_ID) == ACCEL_ID_VALUE; }

void accel_load(uint32_t sel, const int8_t *m, int n) {
  uint32_t hdr = sel << 20;
  int len = n * ACCEL_D;  // addr {row, col} is the row-major index
  for (int i = 0; i < len; i++) REG32(ACCEL_LOAD) = hdr | ((uint32_t)i << 8) | (uint8_t)m[i];
}

void accel_start(int n, int irq) {
  REG32(ACCEL_STATUS) = ACCEL_ST_DONE | (irq ? ACCEL_ST_IRQ_EN : 0);
  REG32(ACCEL_CTRL) = ((uint32_t)n << 8) | 1u;
}

void accel_wait(void) {
  while (!(REG32(ACCEL_STATUS) & ACCEL_ST_DONE)) {
  }
  REG32(ACCEL_IRQ) = 1;
}

void accel_read(int8_t *out, int n) {
  int len = n * ACCEL_D;
  for (int i = 0; i < len; i++) {
    REG32(ACCEL_RD_ADDR) = (uint32_t)i;
    out[i] = (int8_t)REG32(ACCEL_RD_DATA);
  }
}

uint32_t accel_cycles(void) { return REG32(ACCEL_CYCLES); }

uint32_t accel_expected_cycles(int n) {
  uint32_t nb = (uint32_t)n / 4, c = 1;
  for (uint32_t g = 0; g < nb; g++) c += 16 * nb + 156;  // no multiply on rv32i
  return c;
}
