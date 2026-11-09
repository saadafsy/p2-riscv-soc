#!/usr/bin/env bash
# Lint the debug/BIST/clock-gate integration: verilator -Wall on each new
# block, on clk_gate in all three variants, on soc_top and on the Basys 3
# board top (Xilinx primitives from tb/socdbg/stubs; open pins on the vendor
# primitives are allowed there), then verible.
set -uo pipefail
cd "$(dirname "$0")/../.."
S=tb/socdbg/stubs
SOC="$(cat rtl/core/core.f) $(cat rtl/soc.f)"
INC="+incdir+rtl/accel/p1 --timescale 1ns/1ps"
fail=0
log=$(mktemp)

vl() {
  local top=$1; shift
  if verilator --lint-only -Wall --top-module "$top" "$@" >"$log" 2>&1; then
    echo "verilator OK   $top $*" | cut -c1-100
  else
    echo "verilator FAIL $top"; cat "$log"; fail=1
  fi
}

vl obi_arb2     rtl/bus/obi_arb2.sv
vl bist_ram_mux rtl/dft/bist_ram_mux.sv
vl sysctl_apb   rtl/periph/sync2ff.sv rtl/periph/sysctl_apb.sv
vl clk_gate     rtl/clk/clk_gate.sv
vl clk_gate     -DFPGA_XC7 $S/xil_prims.sv rtl/clk/clk_gate.sv
vl clk_gate     -DSKY130 $S/sky130_icg.sv rtl/clk/clk_gate.sv
# shellcheck disable=SC2086
vl soc_top      $INC $SOC
# shellcheck disable=SC2086
vl basys3_top   $INC -Wno-PINCONNECTEMPTY -DFPGA_XC7 $S/xil_prims.sv $SOC fpga/basys3_top.sv
# shellcheck disable=SC2086
vl tb_soc_dbg   $INC $SOC rtl/bus/obi_checker.sv tb/socdbg/tb_soc_dbg.sv
rm -f "$log"

if verible-verilog-lint --rules=line-length=length:100 rtl/bus/obi_arb2.sv \
     rtl/dft/bist_ram_mux.sv rtl/periph/sysctl_apb.sv rtl/clk/clk_gate.sv rtl/soc_top.sv \
     fpga/basys3_top.sv formal/arb_formal_top.sv tb/socdbg/tb_soc_dbg.sv; then
  echo "verible   OK   new rtl, soc_top, basys3_top, formal/arb, tb/socdbg"
else
  echo "verible   FAIL"; fail=1
fi
exit $fail
