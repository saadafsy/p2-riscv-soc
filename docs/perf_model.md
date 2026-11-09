# C++ performance model

`model/perf/p2perf.cpp` is a cycle-approximate model of the SoC. It has two
parts:
- **Functional model:** RV32IM + Zicsr in machine mode, with the same
  conventions as `model/rv32_iss.py`. It also models RAM, the UART with its
  timed TX FIFO, GPIO, the timer, SIMCTRL and timer interrupts.
- **Timing model:** an event-count model of the 5-stage pipeline. Time
  advances per instruction, so programs that poll `mtime` or the UART spin
  for the modeled number of cycles.

```
cycles = instructions + START + 2 * taken (branches, jumps, MRET)
       + 1 * load-use + 3 * MUL + 33 * DIV
       + CSR * csr_instructions + TRAP * traps + INTR * interrupts
       + APB * peripheral_accesses
```

The fixed costs come from the core's documented behavior:
- a taken branch costs 2 cycles and a load-use stall costs 1, both from
  `test_cpi`;
- MUL and DIV latencies come from spec section 3.

The other costs are fitted by `model/perf/calibrate.py`:
- **Fit:** least squares against the RTL cycle counts of the ten directed
  ISA programs, with every cost kept non-negative.
- **Validation:** the C programs, which the fit never sees.
- **RTL counts:** the lockstep SoC run, `tb/soc`, which prints
  `N instructions in C cycles` for each program.

```
make perf      # build the model, refit against build/full/soc73.log, print the table
build/perf/p2perf $(cat model/perf/params.txt) --param UART_DIV=16 build/sw/bench/bench.hex
```

## Result (2026-11-09, RV32IM core)

Fitted values: START 5.47, CSR 3.1, APB 1.88. TRAP came out negative and
is held at 0. INTR is not in the fit, because no fit program takes an
interrupt.

| program | set | RTL instructions | model instructions | RTL cycles | model cycles | error |
|---|---|---|---|---|---|---|
| alu_imm | fit | 307 | 308 | 319 | 320 | +0.3% |
| alu_reg | fit | 439 | 440 | 451 | 452 | +0.2% |
| branch | fit | 249 | 250 | 328 | 329 | +0.3% |
| csr | fit | 231 | 232 | 467 | 452 | -3.2% |
| jump | fit | 80 | 81 | 122 | 123 | +0.8% |
| load | fit | 264 | 265 | 285 | 286 | +0.4% |
| lui_auipc | fit | 55 | 56 | 67 | 68 | +1.5% |
| store | fit | 168 | 169 | 208 | 208 | +0.0% |
| trap | fit | 753 | 754 | 1,389 | 1,395 | +0.4% |
| muldiv | fit | 389 | 390 | 1,676 | 1,677 | +0.1% |
| hello | validation | 4,777 | 4,766 | 9,528 | 9,470 | -0.6% |
| bench (CRC-32 + matrix) | validation | 210,608 | 210,600 | 238,104 | 238,023 | -0.0% |
| timer_irq | validation | 10,865 | 10,837 | 17,698 | 17,627 | -0.4% |
| irq | validation | 2,802 | 2,803 | 4,245 | 4,234 | -0.3% |
| CoreMark, rv32im, 2 iterations | validation | 621,529 | 621,530 | 915,277 | 915,832 | +0.06% |
| CoreMark, rv32i, 2 iterations | validation | 1,460,021 | 1,460,022 | 2,119,473 | 2,120,030 | +0.03% |

The model always counts one more instruction than the RTL: the final store
to SIMCTRL EXIT. The RTL bench stops when it sees that store and does not
count it as retired.

- **CoreMark:** the RTL counts come from the lockstep run in
  `docs/coremark.md`.
- **Speed:** the model runs the 1.46M-instruction CoreMark build in 0.02 s,
  about 70 M instructions per second. The cocotb lockstep simulation runs
  about 9k cycles per second.
- **Not modeled:** the accelerator (`attn_test` and `clkgate_test` read it)
  and testbench-driven external interrupts.
