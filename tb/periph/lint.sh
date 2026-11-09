#!/usr/bin/env bash
# Lint every bus/periph/mem block: verilator -Wall per top, then verible.
set -uo pipefail
cd "$(dirname "$0")/../.."
B=rtl/bus; P=rtl/periph; M=rtl/mem
fail=0

vl() {
  local top=$1; shift
  if verilator --lint-only -Wall --top-module "$top" "$@" >/tmp/p2_lint_$$.log 2>&1; then
    echo "verilator OK   $top $*" | cut -c1-100
  else
    echo "verilator FAIL $top"; cat /tmp/p2_lint_$$.log; fail=1
  fi
}

vl sync2ff     $P/sync2ff.sv
vl sync_fifo   $P/sync_fifo.sv
vl uart_apb    $P/uart_apb.sv $P/sync_fifo.sv $P/sync2ff.sv
vl gpio_apb    $P/gpio_apb.sv $P/sync2ff.sv
vl timer_apb   $P/timer_apb.sv
vl simctrl_apb $P/simctrl_apb.sv
vl simctrl_apb -DSYNTHESIS $P/simctrl_apb.sv
vl dp_ram      $M/dp_ram.sv
vl apb_mux     $B/apb_mux.sv
vl obi2apb     $B/obi2apb.sv $B/apb_mux.sv
vl obi_default_slave $B/obi_default_slave.sv
vl obi_decoder $B/obi_decoder.sv $B/obi_default_slave.sv
vl obi_checker --assert $B/obi_checker.sv
vl obi_checker --assert -GASSUME_M=1 -GASSUME_S=1 $B/obi_checker.sv
vl apb_checker --assert $B/apb_checker.sv
vl apb_checker --assert -GASSUME_M=1 $B/apb_checker.sv
rm -f /tmp/p2_lint_$$.log

if verible-verilog-lint --rules=line-length=length:100 $B/*.sv $P/*.sv $M/*.sv; then
  echo "verible   OK   rtl/bus rtl/periph rtl/mem"
else
  echo "verible   FAIL"; fail=1
fi
exit $fail
