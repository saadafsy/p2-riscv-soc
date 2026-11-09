// Accelerator clock-gate test (docs/spec.md section 13.4). Stops and
// restarts the accelerator clock while idle, then runs N = 16 twice on the
// same random Q, K, V: once ungated, once with the clock stopped right after
// START. While stopped the run must not finish; after the restart it must
// finish with the same 256 output bytes and the same cycle count as the
// ungated run (attention_top counts its own clock cycles). The lockstep
// testbench also checks out_b against p1 attn_fixed and that the gated
// clock really had no edges. Exits 0 without testing when the accelerator
// or SYSCTL is missing (a standalone ISS run).
#include <stdint.h>

#include "accel.h"
#include "printf.h"
#include "soc.h"

#define N 16
#define LEN (N * ACCEL_D)

int8_t q_m[LEN], k_m[LEN], v_m[LEN], out_a[LEN], out_b[LEN];

static uint32_t rng = 0x1F2E3D4Cu;
static int8_t rnd8(void) {
  rng ^= rng << 13;
  rng ^= rng >> 17;
  rng ^= rng << 5;
  return (int8_t)(rng >> 24);
}

// Poll STATUS.ACCEL_CLK_ON until it equals on; 0 on timeout.
static int wait_clk(int on) {
  for (int i = 0; i < 1000; i++) {
    if (((REG32(SYSCTL_STATUS) & SYSCTL_ST_CLK_ON) != 0) == on) return 1;
  }
  return 0;
}

static void load_all(void) {
  accel_load(ACCEL_SEL_Q, q_m, N);
  accel_load(ACCEL_SEL_K, k_m, N);
  accel_load(ACCEL_SEL_V, v_m, N);
}

int main(void) {
  printf_putchar = putchar_sim;
  if (!accel_present() || REG32(SYSCTL_ID) != SYSCTL_ID_VALUE) {
    printf("clkgate_test: no accelerator or SYSCTL, skipped\n");
    return 0;
  }
  // Idle stop and restart.
  REG32(SYSCTL_CTRL) = 0;
  if (!wait_clk(0)) return 1;
  REG32(SYSCTL_CTRL) = SYSCTL_ACCEL_CLK_EN;
  if (!wait_clk(1)) return 2;

  for (int i = 0; i < LEN; i++) {
    q_m[i] = rnd8();
    k_m[i] = rnd8();
    v_m[i] = rnd8();
  }
  load_all();
  accel_start(N, 0);
  accel_wait();
  accel_read(out_a, N);
  uint32_t cyc_a = accel_cycles();

  // Same run, clock stopped just after START.
  load_all();
  accel_start(N, 0);
  REG32(SYSCTL_CTRL) = 0;
  if (!wait_clk(0)) return 3;
  // A full N = 16 run is about 900 accelerator cycles; wait far longer.
  for (int i = 0; i < 1500; i++) {
    uint32_t st = REG32(ACCEL_STATUS);
    if (!(st & ACCEL_ST_BUSY) || (st & ACCEL_ST_DONE)) return 4;
  }
  REG32(SYSCTL_CTRL) = SYSCTL_ACCEL_CLK_EN;
  if (!wait_clk(1)) return 5;
  accel_wait();
  accel_read(out_b, N);
  uint32_t cyc_b = accel_cycles();

  int bad = 0;
  for (int i = 0; i < LEN; i++) bad += out_a[i] != out_b[i];
  printf("clkgate_test: %d mismatches, cycles %u / %u (expected %u)\n", bad, cyc_a, cyc_b,
         accel_expected_cycles(N));
  if (bad) return 6;
  if (cyc_a != accel_expected_cycles(N) || cyc_b != cyc_a) return 7;
  printf("clkgate_test: PASS\n");
  return 0;
}
