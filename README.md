# p2-riscv-soc: a RISC-V SoC with C firmware, verified against a golden model

A small system-on-chip for the Digilent Basys 3 (Artix-7): a 5-stage
pipelined RV32IM core with machine-mode CSRs, traps and interrupts, 64 KB of
on-chip RAM, an OBI interconnect, an AMBA APB peripheral bus (UART, GPIO,
timer), and C firmware built with clang. Every instruction the RTL retires is
checked against a Python instruction-set simulator.

```
            +--------------------------- soc_top ---------------------------+
            |  rv32_core (IF ID EX MEM WB, forwarding, CSRs, traps, irqs)    |
            |     | instr (OBI)            | data (OBI)                      |
            |     v                        v                                 |
            |  dp_ram port A  <------  obi_decoder ----> obi2apb (APB4)      |
            |  (64 KB BRAM)   port B <----'                |                 |
            |                                 UART  GPIO  TIMER  SIMCTRL     |
            +----------------------------------------------------------------+
```

## Results

| | |
|---|---|
| ISA | RV32IM + Zicsr, M-mode: 11 CSR groups, 6 trap causes, timer and external interrupts; multiply 4 cycles, divide 34 cycles |
| Golden model | Python ISS, 288 pytest cases incl. every M corner and deliberately broken variants that must fail |
| Lockstep, directed | 15 programs (11 ISA test groups incl. muldiv, hello, timer-interrupt demo, CRC-32 + matrix benchmark, accelerator test) |
| Lockstep, random | `make rand`: 100 random programs of ~1,500 instructions with M instructions mixed in, every retired instruction compared |
| Core tests | 53 cocotb tests incl. random bus latency and interrupts during multiply/divide |
| Bus and peripherals | cocotb tests with OBI and APB protocol checkers (SVA), negative tests per rule, SymbiYosys BMC |
| Core formal | SymbiYosys BMC depth 30: x0 invariant, retire order, OBI rules, forward progress, M unit progress |
| Performance | CPI 1.00 straight-line, 1.13 on the benchmark; load-use 1 stall, taken branch 2 |
| CoreMark | 2.267 CoreMark/MHz with M, 0.962 without (RTL simulation, 2 iterations; not an official score, see docs/coremark.md) |
| sky130 (core only, pre-layout) | 109 MHz at a 10 ns target with M (113 MHz before), see synth/README.md |
| Artix-7 (synthesis) | SoC before M: ~4.5k LUTs, ~3.5k FFs, 16 RAMB36; the core alone with M is 4.1k LUTs, 3.0k FFs, 4 DSP48E1 (SoC not re-synthesized) |

Not done yet: running on the board (needs Vivado; `fpga/build.tcl` is ready).

## Run it

Tools: Verilator, Yosys, SymbiYosys (OSS CAD Suite), Verible, cocotb, and a
RISC-V clang (lowRISC toolchain in `~/tools/riscv`).

```
make sw       # build ISA tests and C programs, run each on the ISS
make model    # ISS unit tests
make core     # core tests, lint, formal
make periph   # bus/peripheral tests, protocol-checker negatives, formal
make soc      # full SoC vs the ISS on every program
make rand N=100
make -C sw coremark   # then see docs/coremark.md
```

## Layout

```
rtl/core/    rv32_core: fetch, decoder, ALU, multiply/divide, regfile, CSRs, hazard unit
rtl/bus/     OBI decoder, OBI-to-APB bridge, protocol checkers
rtl/periph/  UART, GPIO, timer, simulation control
rtl/mem/     dual-port RAM (BRAM template)
model/       instruction-set simulator, random program generator
sw/          crt0, linker script, drivers, ISA tests, C programs, CoreMark port
third_party/ CoreMark sources (EEMBC, see docs/coremark.md)
tb/          core/, periph/, soc/ (lockstep)
formal/      SymbiYosys setups
fpga/        Basys 3 top, constraints, Vivado build script
docs/spec.md the interface contract between blocks
```
