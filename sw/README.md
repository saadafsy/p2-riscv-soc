# Software and golden model

## Build

```
scripts/build_sw.sh          # all ISA tests and C programs
scripts/build_sw.sh --run    # build, then run each on the ISS
make -C sw hello             # one program
make -C sw asm SRC=/abs/x.S NAME=x
```

Toolchain: lowRISC clang in `~/tools/riscv/bin`, `-march=rv32im_zicsr -mabi=ilp32`
(override with `MARCH=rv32i_zicsr` for a build without M), lld, `-mno-relax`,
freestanding (no libc; `common/rt.S` supplies `memset`, `memcpy` and the
`__mulsi3`, `__udivsi3`, `__umodsi3`, `__divsi3`, `__modsi3` helpers that clang
calls only when M is off).

Each program `<name>` produces `build/sw/<name>/<name>.{elf,bin,hex,dis}`:

- `.bin`: raw image from address 0.
- `.hex`: `$readmemh` image for `dp_ram` `INIT_FILE`: one 32-bit little-endian word per
  line, 8 lowercase hex digits, no `@` records, word *n* = bytes 4n..4n+3, padded with
  zeros to 16384 lines (64 KB). Reset pc is 0.
- `.dis`: `llvm-objdump -d -S`.

## Layout

| Path | Contents |
|---|---|
| `common/crt0.S` | `_start`: sp = 0x10000, clear .bss, mtvec = `_trap_entry`, `main()`, EXIT = return value |
| `common/link.ld` | everything in RAM at 0x0, `.text.init` first |
| `common/soc.h` | register map (spec 5, 8), CSR helpers, `sim_exit`, `sim_putc` |
| `common/uart.c`, `gpio.c`, `timer.c` | drivers |
| `common/printf.c` | `printf` with `%d %i %u %x %X %p %s %c %%`, zero pad and width, `l` accepted |
| `coremark/` | CoreMark port (`core_portme.c/h`) for `third_party/coremark`, see below |
| `isa/*.S` | self-checking ISA tests, one per group; `isa/isa.h` macros |
| `c/hello.c` | prints via UART and SIMCTRL PUTC |
| `c/timer_irq.c` | 5 periodic machine-timer interrupts |
| `c/bench.c` | CRC-32 (4 KB) + 8x8 matmul with known checksums; prints mcycle/minstret |

Traps in C programs: `_trap_entry` saves caller-saved registers and calls
`uint32_t trap_handler(mcause, mepc, mtval)`, which returns the pc to resume at. The weak
default ends the run with EXIT = `0xE0000000 | mcause[7:0]`.

## ISA tests

`alu_reg alu_imm lui_auipc branch jump load store csr trap irq muldiv`. x28 holds the test
number; each test ends with SIMCTRL EXIT = 0 (pass) or the failing test number (an
unexpected trap fails the current test). `irq` uses the TIMER and bounded polling loops,
so it passes whether mtime counts clock cycles or instructions.

## CoreMark

```
make -C sw coremark MARCH=rv32im_zicsr CM_ITER=2   # -> build/coremark/rv32im_zicsr_it2/
make -C sw coremark MARCH=rv32i_zicsr  CM_ITER=2   # same without M
make -C tb/soc PROG_DIR=$PWD/build/coremark SIM_BUILD=sim_build_cm \
  COCOTB_RESULTS_FILE=results_cm.xml MAX_CYCLES=8000000
```

Measured in the lockstep SoC simulation, 2 iterations: 2.267 CoreMark/MHz with M
(882,317 cycles), 0.962 without (2,079,305 cycles). Not an official score (runs far
under the required 10 s); details and the port in `docs/coremark.md`.

## Golden model

```
python3 model/rv32_iss.py build/sw/hello/hello.hex [--trace] [--max-steps N] [--cycles-per-step N]
python3 -m pytest model/tests
python3 model/randgen.py --batch 50 --seed 1      # generate, build, run on the ISS
python3 model/randgen.py --seed 5 -o prog.S --mix alu=40,trap=0 --length 1000
```

`Iss.step()` returns one `Retire` record with the RVFI fields of spec section 3 plus
`cause` (mcause written by this record's trap or the interrupt taken before it) and
`nondet` (value depends on timing: reads of mcycle/cycle/mip or TIMER MTIME). Record
conventions are in the module docstring.

Lockstep: construct `Iss(auto_irq=False)`; when the RTL record has `rvfi_intr` and the
previous record did not trap, call `iss.raise_interrupt("timer" | "external")` before
`step()` (it raises `IssError` if the ISS has that interrupt disabled). For `nondet`
records compare everything except `rd_wdata`/`mem_rdata`, then copy the RTL value into
`iss.x[rd]`.
