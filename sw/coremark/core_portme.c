// CoreMark port for p2-riscv-soc. Derived from the barebones port in
// third_party/coremark (Apache-2.0, EEMBC).
#include <stddef.h>

#include "coremark.h"
#include "printf.h"
#include "soc.h"

#if VALIDATION_RUN
volatile ee_s32 seed1_volatile = 0x3415;
volatile ee_s32 seed2_volatile = 0x3415;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PERFORMANCE_RUN
volatile ee_s32 seed1_volatile = 0x0;
volatile ee_s32 seed2_volatile = 0x0;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PROFILE_RUN
volatile ee_s32 seed1_volatile = 0x8;
volatile ee_s32 seed2_volatile = 0x8;
volatile ee_s32 seed3_volatile = 0x8;
#endif
volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;

ee_u32 default_num_contexts = 1;

// mtime low word: one tick per clock cycle; a run is far below 2^32 cycles.
static CORETIMETYPE start_time_val, stop_time_val;
static ee_u32 instret_start, instret_stop;

void start_time(void) {
  instret_start = csr_read(minstret);
  start_time_val = REG32(TIMER_MTIME_LO);
}

void stop_time(void) {
  stop_time_val = REG32(TIMER_MTIME_LO);
  instret_stop = csr_read(minstret);
}

CORE_TICKS get_time(void) { return (CORE_TICKS)(stop_time_val - start_time_val); }

secs_ret time_in_secs(CORE_TICKS ticks) { return ticks / CLOCK_HZ; }

void portable_init(core_portable *p, int *argc, char *argv[]) {
  (void)argc;
  (void)argv;
  printf_putchar = putchar_sim;
  if (sizeof(ee_ptr_int) != sizeof(ee_u8 *))
    ee_printf("ERROR! Please define ee_ptr_int to a type that holds a pointer!\n");
  if (sizeof(ee_u32) != 4) ee_printf("ERROR! Please define ee_u32 to a 32b unsigned type!\n");
  p->portable_id = 1;
}

// Called with &results[0].port; the CRC check result sits in the same struct.
// Exit code 0 when the list, matrix and state CRCs matched the known values
// (the "must run 10 s" rule is ignored here, it is a short simulation run).
void portable_fini(core_portable *p) {
  core_results *res = (core_results *)((char *)p - offsetof(core_results, port));
  ee_u32 ticks = get_time();
  ee_u32 insns = instret_stop - instret_start;
  p->portable_id = 0;
  ee_printf("p2: cycles %u, instructions %u, iterations %u\n", ticks, insns, res->iterations);
  // CoreMark/MHz = iterations * 1e6 / cycles, printed with 3 decimals.
  ee_u32 kilo = ticks / 1000u;
  if (kilo) {
    ee_u32 x1000 = res->iterations * 1000000u / kilo;
    ee_printf("p2: CoreMark/MHz %u.%03u (not an official score)\n", x1000 / 1000u,
              x1000 % 1000u);
  }
  sim_exit(res->err == 0 && res->crclist != 0 ? 0u : 1u);
}
