#!/usr/bin/env bash
# Lint rtl/debug: verilator -Wall per top, then verible (100 columns).
# bscan_jtag_xilinx.sv is Vivado-only (needs the BSCANE2 / BUFG cells), so it
# gets the verible check only.
set -uo pipefail
cd "$(dirname "$0")/../.."
D=rtl/debug
fail=0
log=$(mktemp)

vl() {
  local top=$1; shift
  if verilator --lint-only -Wall --top-module "$top" "$@" >"$log" 2>&1; then
    echo "verilator OK   $top"
  else
    echo "verilator FAIL $top"; cat "$log"; fail=1
  fi
}

vl cdc_req_ack     $D/cdc_req_ack.sv
vl jtag_tap        $D/jtag_tap.sv
vl jtag_obi_master $D/jtag_obi_master.sv $D/cdc_req_ack.sv
vl jtag_debug      $D/jtag_debug.sv $D/jtag_tap.sv $D/jtag_obi_master.sv $D/cdc_req_ack.sv
rm -f "$log"

if verible-verilog-lint --rules=line-length=length:100 $D/*.sv; then
  echo "verible   OK   rtl/debug"
else
  echo "verible   FAIL"; fail=1
fi
exit $fail
