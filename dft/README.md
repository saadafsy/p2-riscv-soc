# DFT: scan insertion and stuck-at ATPG

`bash dft/run_fault.sh <top> <clock> <reset> [active_low] -- <rtl files>`
takes one block from RTL to a scan-inserted netlist and a stuck-at test set.
It runs on the sky130_fd_sc_hd typical liberty. `make dft` runs it on every
block in the table.

1. **yosys** synthesizes the block to sky130 cells, flattened. Every flop is
   a plain `dfxtp`, since the design uses synchronous resets.
2. **`gen_cells.py`** builds behavioral Verilog models of the liberty cells
   from their `function` and `ff` attributes. The simulations below use them.
3. **`fault cut`** turns every flop into a pseudo input and output. This is
   the full-scan view.
4. **`nl2bench` and `quaigh atpg`** generate the patterns. Random patterns
   run first, then a SAT search for each remaining fault, then compaction.
   Faults are input and output stuck-at faults on every gate, collapsed to
   unique faults.
5. **`fault chain`** puts a scan mux in front of every flop and stitches one
   chain from the internal flops plus boundary cells on the ports. It adds
   `shift`, `test`, `sin` and `sout`, resynthesizes, and checks
   shift-in/shift-out of the chain in iverilog.

The tools are the ones in `ghcr.io/aucohl/fault`, run through Docker. Fault's
own `atpg` crashes in that image (SIGILL, even on its bundled ISCAS
benchmarks), so step 4 uses quaigh, which ships in the same image.

## Results (2026-11-09)

| Block | Cells | Flops | Area (um^2) | Collapsed faults | Detected | Coverage | Patterns | Scan chain (internal + boundary) | Chain check |
|---|---|---|---|---|---|---|---|---|---|
| gpio_apb | 200 | 58 | 2,121 | 878 | 822 | 93.6% | 73 | 58 + 125 = 183 | pass |
| timer_apb | 1,069 | 128 | 7,854 | 5,502 | 5,242 | 95.3% | 559 | 128 + 89 = 217 | pass |
| uart_apb | 1,445 | 363 | 15,263 | 7,764 | 7,710 | 99.3% | 805 | 363 + 91 = 454 | pass |

The faults counted as undetected are those quaigh's SAT search found no
pattern for in the full-scan view. They have not been classified one by one.
Coverage is over collapsed stuck-at faults. It does not cover transition
faults or at-speed test.

Everything here is netlist-level. There is no ATE, no silicon, and no
tester program.
