# Physical design (OpenROAD-flow-scripts, sky130hd)

`bash pd/run_orfs.sh <design>` runs the full RTL-to-GDS flow on one block
in the `openroad/orfs` Docker image: yosys synthesis, floorplan and power
grid, global and detailed placement, clock-tree synthesis, global and
detailed routing, parasitic extraction, signoff STA, and the final GDS. The
repo is copied into the container, and results come back to
`build/orfs/<design>/`:
- `reports/.../metadata.json` holds the numbers below;
- `6_finish.rpt` holds timing and power;
- `results/.../6_final.gds` is the layout.

Needs Docker; set `DOCKER=` to the CLI path if `docker` is not on PATH.

## rv32_core

`pd/rv32_core/rv32_core_pd.sv` is the core as it sits in `soc_top`. The
RVFI trace port is left open, so the trace-only logic is removed.

| Setting | Value |
|---|---|
| Clock | 10 ns |
| I/O delay | 20% of the period on each side of the core boundary |
| Core utilization | 40% |

Results for the RV32I + Zicsr core (commit a406c87), 2026-11-09:

| Metric | Result |
|---|---|
| Setup WNS / TNS | +1.36 ns / 0 |
| Signoff Fmax | 115.8 MHz |
| Hold WNS | +0.45 ns |
| Clock skew | 0.12 ns |
| Std cells | 17,555 (128,735 um^2), 45% utilization |
| Die | 290,230 um^2 (about 0.54 x 0.54 mm) |
| Detailed-route DRC errors | 0 |
| Antenna violations | 0 |
| Max slew / cap / fanout violations | 0 / 0 / 0 |
| Power (tt corner, default activity) | 18.7 mW |
| GDS | written (`6_final.gds`) |

These are OpenROAD signoff numbers at the typical corner, after routing and
parasitic extraction. The design was not taped out, and there is no
silicon measurement. Power uses the tool's default switching activity, not
a simulation trace.
