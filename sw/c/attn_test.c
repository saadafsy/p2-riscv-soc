// Attention accelerator test (docs/spec.md section 12). For N = 4, 16, 64:
// random int8 Q, K, V (fixed seed), run the accelerator, compute the same
// head in C with a bit-exact port of p1 model/attn.py attn_fixed, compare
// every output byte, check the cycle count. N = 16 waits on the interrupt.
// Exits 0 when everything matches; on a standalone ISS run (no accelerator)
// it reports a skip and exits 0.
//
// rv32i has no multiplier, so the reference avoids general multiplies (the
// lockstep bench runs every instruction against the ISS):
// - Q.K: k as bit planes; per query row, subset-sum tables of q over each
//   half of the 16 columns turn a 16-term dot product into 16 lookups.
// - w * v: per (row, key), a table of n * w for n in 0..15, applied to the
//   nibbles of v + 128; the 128 w excess is summed once per segment of keys
//   between running-max changes and taken off before the next rescale
//   (uint32 arithmetic, so the excess wraps out exactly).
// - acc * r (only when the running max moves): 16-bit halves with a nibble
//   table of r, exact by the split rshr(x r, 15) = 2 xh r + rshr(xl r, 15).
// - the final divide: 8-bit restoring division (the result saturates to int8).
// All integer arithmetic matches attn_fixed exactly (same widths, rounding
// and saturation; same LUT, generated from p1's model/exp_lut.hex).
#include <stdint.h>

#include "accel.h"
#include "accel_exp_lut.h"
#include "printf.h"
#include "soc.h"
#include "timer.h"

#define D ACCEL_D
#define NMAX ACCEL_N_MAX
#define M_INIT (-32768)
#define EXP_ONE 32768

static int8_t q_m[NMAX * D], k_m[NMAX * D], v_m[NMAX * D];
static int8_t out_hw[NMAX * D], out_ref[NMAX * D];
static int16_t tbl[512];                // subset sums of q over columns 0-7, 8-15
static const int16_t *kptr[NMAX][16];   // [2b + h]: &tbl[256 h + plane b of k half h]
// Per key j of the current row: slot[j][n] = n * w (add step) or n * r
// (running-max step) for n = 0..15. Pass 1 lists the add steps
// (adds[]) and the running-max steps (ev_*: key, position in adds[], and the
// 128 w excess of the segment that ends there).
static int32_t slot[NMAX][16];
static const int32_t *vptr[NMAX][D][2]; // &slot[j][(v + 128) >> 4], &slot[j][(v + 128) & 15]
static const int32_t *(*adds[NMAX])[2];  // vptr[j] of each add step, in key order
static uint8_t ev_j[NMAX], ev_pos[NMAX + 1];
static uint32_t ev_excess[NMAX + 1];

static uint32_t rng = 0x2545F491u;
static int8_t rnd8(void) {
  rng ^= rng << 13;
  rng ^= rng >> 17;
  rng ^= rng << 5;
  return (int8_t)(rng >> 24);
}

// ---------------------------------------------------------------- reference
static void build_kv_tables(int n) {
  for (int j = 0; j < n; j++) {
    for (int h = 0; h < 2; h++) {
      for (int b = 0; b < 8; b++) {
        uint32_t m = 0;
        for (int d = 0; d < 8; d++) m |= (((uint32_t)(uint8_t)k_m[j * D + 8 * h + d] >> b) & 1u) << d;
        kptr[j][2 * b + h] = &tbl[256 * h + m];
      }
    }
    for (int d = 0; d < D; d++) {
      int v = v_m[j * D + d] + 128;
      vptr[j][d][0] = &slot[j][v >> 4];
      vptr[j][d][1] = &slot[j][v & 15];
    }
  }
}

static void build_q_table(const int8_t *q) {
  for (int h = 0; h < 2; h++) {
    int16_t *t = &tbl[256 * h];
    t[0] = 0;
    for (int d = 0; d < 8; d++) {
      int step = 1 << d, qd = q[8 * h + d];
      int16_t *dst = t + step;
#pragma clang loop unroll_count(4)
      for (int m = 0; m < step; m++) dst[m] = (int16_t)(t[m] + qd);
    }
  }
}

// attn.py lut_index: clamp d_raw (<= 0) to -16384, idx = (-d_raw + 8) >> 4,
// cap 1023. Every d_raw < -16360 gives 1023 either way, so the cap suffices.
static int lut_index(int32_t d_raw) {
  int idx = (8 - d_raw) >> 4;
  return idx < 1024 ? idx : 1023;
}

static uint32_t mul16_r(const int32_t *rt, uint32_t u) {  // u (16 bits) * r, rt[n] = n r
  uint32_t p = (uint32_t)rt[u & 15] + ((uint32_t)rt[(u >> 4) & 15] << 4);
  if (u >> 8) p += ((uint32_t)rt[(u >> 8) & 15] << 8) + ((uint32_t)rt[u >> 12] << 12);
  return p;
}

// rshr(x * r, 15) for 0 <= r <= 32768, exact: x = 65536 xh + xl, and
// rshr(65536 xh r + xl r, 15) = 2 xh r + rshr(xl r, 15). uint32 wraps; the
// result fits int32 (uarch 3.7).
__attribute__((noinline)) static uint32_t mul_rshr15(uint32_t x, const int32_t *rt) {
  int32_t xh = (int32_t)x >> 16;
  uint32_t ah = xh < 0 ? (uint32_t)-xh : (uint32_t)xh;  // <= 32768
  uint32_t hr = mul16_r(rt, ah);
  if (xh < 0) hr = 0u - hr;
  return 2u * hr + ((mul16_r(rt, x & 0xFFFFu) + 16384u) >> 15);
}

// sat8(floor((2 acc + l) / (2 l))) (divr, then the defensive saturation).
static int8_t div_out(int32_t acc, uint32_t l) {
  int64_t a = 2 * (int64_t)acc + l;
  uint32_t b = 2 * l, q = 0;
  if (a >= 0) {
    if (a >= (int64_t)b * 128) return 127;
    uint32_t ua = (uint32_t)a;
    for (int k = 6; k >= 0; k--)
      if (ua >= (b << k)) { ua -= b << k; q |= 1u << k; }
    return (int8_t)q;
  }
  int64_t ap = -a;  // floor(a / b) = -ceil(ap / b)
  if (ap > (int64_t)b * 128) return -128;
  uint32_t ua = (uint32_t)ap + b - 1;
  for (int k = 7; k >= 0; k--)
    if (ua >= (b << k)) { ua -= b << k; q |= 1u << k; }
  return (int8_t)(-(int32_t)q);
}

// One query row. Pass 1 walks the keys in order for m and l and records
// each step; pass 2 replays the steps on acc, 8 columns at a time.
static void attn_row(int i, int n) {
  build_q_table(&q_m[i * D]);
  int32_t m = M_INIT;
  uint32_t l = 0, ex = 0;
  int na = 0, ne = 0;
  for (int j = 0; j < n; j++) {
    // sacc = q_i . k_j (exact), plane 7 has weight -128
    const int16_t *const *kp = kptr[j];
    int32_t x = -(*kp[14] + *kp[15]);
    for (int b = 6; b >= 0; b--) x = 2 * x + *kp[2 * b] + *kp[2 * b + 1];
    // rshr(sacc, 2 + D_SHIFT). sat16 is a no-op: |sacc| <= 16 * 128 * 128.
    int32_t s = (x + 8) >> 4;
    int32_t *sl = slot[j];
    if (s > m) {  // new running max: w = lut[0] = 1.0, r = lut[idx(m - s)]
      int32_t r = accel_exp_lut[lut_index(m - s)];
      m = s;
      ev_j[ne] = (uint8_t)j;
      ev_pos[ne] = (uint8_t)na;
      ev_excess[ne++] = ex;
      ex = 0;
      int32_t u = 0;
      for (int t = 0; t < 16; t++) { sl[t] = u; u += r; }
      l = (r ? mul_rshr15(l, sl) : 0u) + EXP_ONE;
    } else {  // r = 1.0: l * r and acc * r are exact
      int32_t w = accel_exp_lut[lut_index(s - m)];
      if (w == 0) continue;
      l += (uint32_t)w;
      ex += (uint32_t)w << 7;
      adds[na++] = vptr[j];
      int32_t u = 0;
      for (int t = 0; t < 16; t++) {
        sl[t] = u;
        __asm__("" : "+r"(u));  // keep the running sum (one add per entry)
        u += w;
      }
    }
  }
  ev_pos[ne] = (uint8_t)na;
  ev_excess[ne] = ex;
  for (int h = 0; h < D; h += 8) {
    uint32_t acc[8] = {0};  // + the excess of the current segment
    int k = 0;
    for (int e = 0;; e++) {
      for (int end = ev_pos[e]; k < end; k++) {
        const int32_t *(*vp)[2] = adds[k] + h;
#pragma clang loop unroll(full)
        for (int d = 0; d < 8; d++) acc[d] += (uint32_t)(*vp[d][0] * 16 + *vp[d][1]);
      }
      if (e == ne) break;
      const int32_t *rt = slot[ev_j[e]];
      const int8_t *vr = &v_m[ev_j[e] * D + h];
      uint32_t exs = ev_excess[e];
      if (rt[1] == 0) {  // r = 0 (the first key, typically): acc restarts
#pragma clang loop unroll(full)
        for (int d = 0; d < 8; d++) acc[d] = (uint32_t)(vr[d] * EXP_ONE);
      } else {
#pragma clang loop unroll(full)
        for (int d = 0; d < 8; d++)
          acc[d] = mul_rshr15(acc[d] - exs, rt) + (uint32_t)(vr[d] * EXP_ONE);
      }
    }
    for (int d = 0; d < 8; d++) out_ref[i * D + h + d] = div_out((int32_t)(acc[d] - ev_excess[ne]), l);
  }
}

static void attn_ref(int n) {
  build_kv_tables(n);
  for (int i = 0; i < n; i++) attn_row(i, n);
}

// ---------------------------------------------------------------- test
static volatile int irq_seen;

uint32_t trap_handler(uint32_t mcause, uint32_t mepc, uint32_t mtval) {
  (void)mtval;
  if (mcause != MCAUSE_IRQ_EXT || !(REG32(ACCEL_IRQ) & 1u)) sim_exit(0xE0000000u | (mcause & 0xFF));
  REG32(ACCEL_IRQ) = 1;  // clear DONE, which drops the irq
  irq_seen = 1;
  return mepc;
}

static int run(int n, int use_irq) {
  for (int i = 0; i < n * D; i++) {
    q_m[i] = rnd8();
    k_m[i] = rnd8();
    v_m[i] = rnd8();
  }
  accel_load(ACCEL_SEL_Q, q_m, n);
  accel_load(ACCEL_SEL_K, k_m, n);
  accel_load(ACCEL_SEL_V, v_m, n);
  irq_seen = 0;
  if (use_irq) {
    csr_set(mie, MIE_MEIE);
    irq_enable();
  }
  accel_start(n, use_irq);
  attn_ref(n);  // overlaps the accelerator run
  if (use_irq) {
    while (!irq_seen) __asm__ volatile("wfi");
    irq_disable();
    csr_clear(mie, MIE_MEIE);
  } else {
    accel_wait();
  }
  accel_read(out_hw, n);
  int bad = 0;
  for (int i = 0; i < n * D; i++) {
    if (out_hw[i] != out_ref[i]) {
      if (bad < 4) printf("  mismatch [%d][%d]: accel %d, ref %d\n", i / D, i % D, out_hw[i], out_ref[i]);
      bad++;
    }
  }
  uint32_t cyc = accel_cycles(), exp = accel_expected_cycles(n);
  printf("attn_test: N=%d %s, %d bytes, %d mismatches, %u accel cycles (expected %u)\n", n,
         use_irq ? "irq" : "poll", n * D, bad, cyc, exp);
  return bad != 0 || cyc != exp;
}

#ifdef SPEEDUP
// Wall time in CPU clock cycles (mcycle) for the same attention problem:
// accelerator end to end (load Q/K/V, compute, read out) versus the software
// reference above on the RV32IM core. Runs are not overlapped here.
static int speedup(int n) {
  for (int i = 0; i < n * D; i++) {
    q_m[i] = rnd8();
    k_m[i] = rnd8();
    v_m[i] = rnd8();
  }
  uint32_t t0 = csr_read(mcycle);
  accel_load(ACCEL_SEL_Q, q_m, n);
  accel_load(ACCEL_SEL_K, k_m, n);
  accel_load(ACCEL_SEL_V, v_m, n);
  uint32_t t1 = csr_read(mcycle);
  accel_start(n, 0);
  accel_wait();
  uint32_t t2 = csr_read(mcycle);
  accel_read(out_hw, n);
  uint32_t t3 = csr_read(mcycle);
  attn_ref(n);
  uint32_t t4 = csr_read(mcycle);
  int bad = 0;
  for (int i = 0; i < n * D; i++) bad += out_hw[i] != out_ref[i];
  uint32_t hw = t3 - t0, sw = t4 - t3;
  printf("speedup: N=%d load %u + compute %u + read %u = %u cycles accel, %u cycles software, x%u.%02u, %d mismatches\n",
         n, t1 - t0, t2 - t1, t3 - t2, hw, sw, sw / hw, (sw % hw) * 100 / hw, bad);
  return bad;
}
#endif

int main(void) {
#ifdef SPEEDUP
  printf_putchar = putchar_sim;
  if (!accel_present()) return 1;
  return speedup(16) + speedup(64);
#endif
#ifdef BOARD
  printf_putchar = putchar_uart;  // board build: results on the USB-UART
#else
  printf_putchar = putchar_sim;   // simulation: SIMCTRL console only (fast)
#endif
  if (!accel_present()) {
    printf("attn_test: no accelerator (ID 0x%08x), skipped\n", REG32(ACCEL_ID));
    return 0;
  }
  int fails = 0;
  fails += run(4, 0);
  fails += run(16, 1);
  fails += run(64, 0);
  printf("attn_test: %s\n", fails ? "FAIL" : "PASS");
  return fails;
}
