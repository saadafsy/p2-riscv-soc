// Attention accelerator driver (docs/spec.md section 12).
#ifndef ACCEL_H
#define ACCEL_H
#include <stdint.h>

#define ACCEL_BASE     0x20000000u
#define ACCEL_CTRL     (ACCEL_BASE + 0x00)  // [0] START (W), [14:8] N_LEN
#define ACCEL_STATUS   (ACCEL_BASE + 0x04)  // [0] BUSY, [1] DONE (W1C), [2] IRQ_EN, [3] ACCEL_BUSY
#define ACCEL_LOAD     (ACCEL_BASE + 0x08)  // [7:0] data, [17:8] {row, col}, [21:20] sel
#define ACCEL_RD_ADDR  (ACCEL_BASE + 0x0C)  // [9:0] {row, col}
#define ACCEL_RD_DATA  (ACCEL_BASE + 0x10)  // [7:0], read waits for the byte
#define ACCEL_CYCLES   (ACCEL_BASE + 0x14)  // attention_top cycles of the last run
#define ACCEL_IRQ      (ACCEL_BASE + 0x18)  // [0] pending (R), write 1 to clear DONE
#define ACCEL_ID       (ACCEL_BASE + 0x1C)
#define ACCEL_ID_VALUE 0x4154544Eu          // "ATTN"

#define ACCEL_ST_BUSY   (1u << 0)
#define ACCEL_ST_DONE   (1u << 1)
#define ACCEL_ST_IRQ_EN (1u << 2)

#define ACCEL_SEL_Q 0u
#define ACCEL_SEL_K 1u
#define ACCEL_SEL_V 2u
#define ACCEL_D     16  // head dimension
#define ACCEL_N_MAX 64

int accel_present(void);
// Load an n x 16 int8 matrix (row-major) into Q, K or V. Accelerator must be idle.
void accel_load(uint32_t sel, const int8_t *m, int n);
// Start a run of length n (multiple of 4, 4..64); irq selects DONE as an interrupt.
void accel_start(int n, int irq);
void accel_wait(void);  // poll until DONE, then clear it
// Read the n x 16 int8 result (row-major).
void accel_read(int8_t *out, int n);
uint32_t accel_cycles(void);
// attention_top's cycle count for length n: nblk * (16 nblk + 156) + 1, nblk = n / 4.
uint32_t accel_expected_cycles(int n);

#endif
