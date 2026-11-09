# p2-riscv-soc: a RISC-V SoC with C firmware, verified against a golden model

A small system-on-chip for the Digilent Basys 3 (Artix-7): a 5-stage
pipelined RV32I core with machine-mode CSRs, traps and interrupts, 64 KB of
on-chip RAM, an OBI interconnect, an AMBA APB peripheral bus (UART, GPIO,
timer), and C firmware built with clang. Every instruction the RTL retires is
checked against a Python instruction-set simulator.

```
     +------------------------------ soc_top -------------------------------+
     |  rv32_core (IF ID EX MEM WB)        JTAG TAP + debug master (tck)     |
     |     | instr          | data              | OBI                        |
     |     |                +---- obi_arb2 -----+  (round-robin)             |
     |     v                         |                                       |
     |  dp_ram port A          obi_decoder ---> obi2apb (APB4) ---> UART GPIO |
     |  (64 KB BRAM) port B <-- bist mux  \        TIMER SYSCTL SIMCTRL      |
     |                 March C- BIST -'    \--> obi2axil -> attention accel  |
     |                                           (own clock, clock-gated)    |
     +----------------------------------------------------------------------+
```

SYSCTL (0x1000_3000) holds the core in reset for JTAG program loading,
starts the RAM BIST and gates the accelerator clock (docs/spec.md section 13).

## Results

| | |
|---|---|
| ISA | RV32I + Zicsr, M-mode: 11 CSR groups, 6 trap causes, timer and external interrupts |
| Golden model | Python ISS, 217 unit tests (including deliberately broken variants that must fail) |
| Lockstep, directed | 13 programs (10 ISA test groups, hello, timer-interrupt demo, CRC-32 + matrix benchmark) |
| Lockstep, random | 120 random programs of ~1,500 instructions, every retired instruction compared |
| Core tests | 41 cocotb tests incl. random bus latency; deliberate-bug mutations all caught |
| Bus and peripherals | cocotb tests with OBI and APB protocol checkers (SVA), negative tests per rule, SymbiYosys BMC |
| Core formal | SymbiYosys BMC depth 30: x0 invariant, retire order, OBI rules, forward progress |
| Performance | CPI 1.00 straight-line, 1.17 on the benchmark; load-use 1 stall, taken branch 2 |
| Lockstep with the debug logic | all 15 programs in `build/sw` (incl. `attn_test`, `clkgate_test`) at accelerator clocks 73 and 137 MHz, 100 random programs; JTAG idle |
| JTAG, BIST, clock gate (SoC level) | 4 cocotb tests with OBI checkers on every new link: JTAG traffic while `bench` runs in lockstep, JTAG program load and boot, BIST pass and stuck-at fail, clock stopped mid-run with the result equal to p1 `attn_fixed` |
| Arbiter formal | SymbiYosys BMC depth 32 + cover: OBI rules on all links, exclusive grants, routing, fairness; three seeded bugs caught |
| Artix-7 (synthesis) | ~4.5k LUTs, ~3.5k FFs, 16 RAMB36 (22% of a Basys 3's LUTs) |

Not done yet: running on the board (needs Vivado; `fpga/build.tcl` is ready).
The FPGA-only parts (BSCANE2 JTAG, BUFGCE clock gate) are linted against
primitive stubs but not simulated or built in this change; the synthesis
figures above predate them.

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
make socdbg   # JTAG / core hold / BIST / clock gate: lint, latch check, formal, SoC tests
```

## Layout

```
rtl/core/    rv32_core: fetch, decoder, ALU, regfile, CSRs, hazard unit
rtl/bus/     OBI decoder, 2-master arbiter, OBI-to-APB and OBI-to-AXI4-Lite bridges, checkers
rtl/periph/  UART, GPIO, timer, system control (SYSCTL), simulation control
rtl/mem/     dual-port RAM (BRAM template)
rtl/accel/   attention accelerator (from p1) as an AXI4-Lite peripheral
rtl/debug/   JTAG TAP and debug transport (OBI master)
rtl/dft/     March C- memory BIST, RAM port mux
rtl/clk/     clock gate (sky130 ICG cell, BUFGCE, or behavioral model)
rtl/soc.f    SoC source list outside rtl/core (used by every flow)
model/       instruction-set simulator, random program generator
sw/          crt0, linker script, drivers, ISA tests, C programs
tb/          core/, periph/, soc/ (lockstep), accel/, debug/, dft/, socdbg/
formal/      SymbiYosys setups
fpga/        Basys 3 top, constraints, Vivado build script
docs/spec.md the interface contract between blocks
```
