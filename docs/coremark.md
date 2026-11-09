# CoreMark on p2-riscv-soc

**Not an official or certified CoreMark score.** The EEMBC run rules ask for at
least 10 s of timed execution and a reported, reproducible setup; these are
2-iteration runs in RTL simulation (lockstep against the ISS), so CoreMark itself
prints `ERROR! Must execute for at least 10 secs` and `Errors detected`. The
CRC checks pass. The figure below is CoreMark/MHz computed from the measured
cycle count.

## Result (2026-11-09)

`soc_top` RTL in Verilator, every retired instruction checked against
`model/rv32_iss.py` (tb/soc lockstep), 2 iterations, 2K performance-run
parameters (seeds 0, 0, 0x66, TOTAL_DATA_SIZE 2000), clang -O2.

| build | timed cycles | timed instructions | CPI | CoreMark/MHz |
|---|---|---|---|---|
| `-march=rv32im_zicsr` (M extension) | 882,317 | 598,231 | 1.47 | 2.267 |
| `-march=rv32i_zicsr` (no M, `rt.S` helpers for * / %) | 2,079,305 | 1,432,059 | 1.45 | 0.962 |

CoreMark/MHz = iterations x 10^6 / timed cycles. The M extension gives 2.36x on
this core (multiply 4 cycles, divide 34 cycles in EX). Both builds report the
known CRCs for these seeds: seedcrc 0xe9f5, crclist 0xe714, crcmatrix 0x1fd7,
crcstate 0x8e3a (crcfinal 0x72be for 2 iterations); the port exits 0 only when
CoreMark's own CRC check found no error. Whole run including setup and output:
621,529 instructions in 915,277 cycles (M), 1,460,021 in 2,119,473 (no M).

Timer: TIMER `mtime` low word, one tick per clock cycle, read in
`start_time`/`stop_time`, so ticks are core cycles (memory has no wait states:
code and data in the on-chip RAM). At the Basys 3's 100 MHz that would be
about 226 iterations/s with M; the run was not done on the board.

## How to reproduce

```
make -C sw coremark MARCH=rv32im_zicsr CM_ITER=2
make -C sw coremark MARCH=rv32i_zicsr  CM_ITER=2
make -C tb/soc PROG_DIR=$PWD/build/coremark SIM_BUILD=sim_build_cm \
  COCOTB_RESULTS_FILE=results_cm.xml MAX_CYCLES=8000000
```

Outputs: `build/coremark/<MARCH>_it<N>/coremark.{elf,bin,hex,dis}`. The bench
prints CoreMark's report plus `p2: cycles ..., instructions ..., iterations ...`
and `p2: CoreMark/MHz` (from cycles / 1000, so its last digit can be off by
one; the table uses the exact cycle count). The lockstep run of both builds
took about 6 minutes of wall time. The ISS alone
(`python3 model/rv32_iss.py build/coremark/rv32im_zicsr_it2/coremark.hex`) runs
the same program at one cycle per instruction, so its CoreMark/MHz is
meaningless; use it only to check the CRCs.

## Port

- `third_party/coremark/`: upstream https://github.com/eembc/coremark at commit
  1f483d5b8316753a742cbf5590caf5bd0a4e4777, unmodified. Kept: the benchmark
  sources, `LICENSE.md`, `README.md`, `barebones/` (the template the port is
  derived from), `coremark.md5`; the other OS ports, docs and CI files were not
  copied. CoreMark is Apache-2.0 with the EEMBC acceptable-use terms in
  `LICENSE.md` (the name may not be used for results from modified sources).
- `sw/coremark/core_portme.h`, `core_portme.c`: bare metal, `HAS_FLOAT 0`,
  `MEM_STACK`, `SEED_VOLATILE`, no argc. `ee_printf` is the project
  `printf` (taught to accept the `l` length modifier) writing to SIMCTRL PUTC;
  `portable_fini` prints the cycle and instruction counts and ends the run with
  SIMCTRL EXIT = 0 when CoreMark's CRC check passed, 1 otherwise.
- Built by `sw/Makefile` target `coremark` with crt0, rt.S, printf and the
  UART driver, linked into the 64 KB RAM (image about 14 KB).
