# synth/: rv32_core synthesis and static timing

Standalone flow for the RV32I core only (`rtl/core/core.f`, in that order). The
SoC top, bus and peripherals are not part of it. Adapted from the p1-attention
flow; everything it needs is in this directory.

## Commands (WSL, from the repo root)

```
export PATH=$HOME/oss-cad-suite/bin:$HOME/tools/bin:$PATH
make -C synth sta-core              # sky130 netlist + OpenSTA + summary, PERIOD_NS=10
make -C synth sta-core PERIOD_NS=8  # other clock target (also the ABC delay target)
make -C synth fpga-core             # Xilinx 7-series resource count
make -C synth clean                 # removes build/synth/
```

Overrides: `LIB=<sky130_fd_sc_hd__tt_025C_1v80.lib>` (default
`$HOME/tools/lib/...`), `TOP=`, `XC7_FAMILY=`.

| file | role |
|---|---|
| `Makefile` | targets above; recipes run with `pipefail`, so a failing tool fails the target |
| `abc_timing.abc` | ABC script, `{D}` replaced by the delay target in ps |
| `sta.tcl` | OpenSTA: clock on `clk`, zero I/O delay, all-path worst, every reg->reg endpoint (`-format end`), 400 full reg->reg paths, in->reg, reg->out, in->out, hold |
| `sta_summary.py` | WNS, TNS, Fmax, worst endpoint groups by RTL bus; anonymous flops named by their Q net in the netlist |
| `fpga_summary.py` | rolls `stat` into LUT/FF/CARRY/DSP/BRAM |

Outputs in `build/synth/`: `rv32_core_sky130_netlist.v`, `synth_rv32_core_sky130.log`,
`sta_rv32_core.log`, `sta_rv32_core_summary.txt`, `fpga_rv32_core.log`,
`fpga_rv32_core_summary.txt`.

Flow: `proc; setattr keep; synth -booth -flatten -run :fine; techmap kogge-stone;
synth -run fine:; dfflibmap; abc -D <ps> -script abc_timing; opt_clean; stat;
write_verilog -noattr`, then `signed` stripped from declarations for OpenSTA.

## Results (2026-11-08, Yosys 0.70+286, OpenSTA 3.1.0)

sky130_fd_sc_hd tt_025C_1v80, pre-layout (ideal clock, liberty wire load, no
placement). Tool estimates, not silicon.

| PERIOD_NS (= ABC target) | WNS | min period | Fmax | violating reg->reg endpoints | area um^2 |
|---|---|---|---|---|---|
| 10 | +1.191 ns | 8.809 ns | 113.5 MHz | 0 / 3785 | 135496 |
| 8  | -0.578 ns | 8.578 ns | 116.6 MHz | 65 / 3785, TNS -23.0 ns | 135499 |

Fmax depends on the ABC delay target (it stops optimizing once it believes the
target is met), so the 10 ns run is a lower bound. Hold: worst +0.069 ns, MET.
Cells: 2825 flops (1801 dfxtp + 1024 edfxtp, the register file is 32x32 reset flops).

Worst path (both targets): registered forwarding select `fwd_b[0]` (fanout 49)
-> forwarding mux B -> `fwd_rs2` -> store lane shift by `alu_y[1:0]` (ALU add)
-> `mem_wdata` / `mem_rvfi_wdata`; next groups `mem_tval` and `mem_wdata`, same
cone. Other groups at 10 ns: in->reg +1.726 ns (`d_rdata[15]`), reg->out
+8.264 ns, in->out +9.050 ns (`d_rvalid` -> `d_req`).

Timing changes (behavior unchanged; tb/core 41/41, lint, formal PASS after each kept step):

| step | change | WNS @10 ns | WNS @8 ns |
|---|---|---|---|
| before | worst path `wb_addr[0]` -> load align -> `wb_value` -> fwd -> ALU -> `ld_mis` -> `ex_do` -> `redirect` -> fetch queue clear | -0.578 | -0.912 |
| 1 alone | `ld_mis`/`st_mis` from `fwd_rs1[1:0] + ex_imm[1:0]` | -0.801 | -1.695 |
| 2 alone | redirect clears only the fetch queue `count`, not `q0`/`q1` data | -0.678 | -1.651 |
| 3 alone | load lane/fill/sign selects decoded in MEM, registered one-hot | -0.470 | -0.921 |
| 1+2+3 | | +0.498 | -0.773 |
| +4 | forwarding selects computed from next-cycle pipeline state and registered (FORMAL assert ties them to the direct compare), two kept copies per operand (bits 15:0 / 31:16) | +1.191 | -0.578 |

Steps 1 and 2 alone made ABC's mapping worse (the same cone surfaced at
`fetch_pc`/`mem_pc_next`/`u_csr`); together with 3 they help, so all are kept.
One copy of the forwarding select per operand gave +0.888 / -1.086 (fanout 57);
the duplicate fixed that. CSR address pre-decode in ID was not needed (the CSR
groups are no longer near the top).
## Xilinx 7-series (yosys `synth_xilinx -family xc7`, pre-place-and-route)

| LUT | FF | CARRY4 | MUXF7/F8 | DSP | BRAM | LUTRAM |
|---|---|---|---|---|---|---|
| 3518 | 2802 | 100 | 2 / 1 | 0 | 0 | 0 |

Before the timing changes: 3611 LUT, 2776 FF (now -93 LUT, +26 FF: the registered
load selects and forwarding selects).

No BRAM/LUTRAM because the register file has a synchronous reset of all 32 entries.

## Caveats

- `abc` is given no `dont_use`, so it may pick `lpflow_*` cells (seen on the
  redirect buffer tree); an OpenLane run would exclude them.
- Zero input/output delay: the bus side owns the port budget.
