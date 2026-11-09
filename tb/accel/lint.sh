#!/usr/bin/env bash
# Lint the accelerator integration: verilator -Wall per top, then verible on
# the files written for P2 (rtl/accel/p1 is p1's code, linted by p1).
set -uo pipefail
cd "$(dirname "$0")/../.."
A=rtl/accel; P1="$A/p1/mac_unit.sv $A/p1/matmul_tile.sv $A/p1/exp_lut_1p.sv $A/p1/sync_ram.sv
$A/p1/online_softmax.sv $A/p1/attention_top.sv"
# p1's files carry a timescale and P2's do not; give the rest the same one.
INC="+incdir+$A/p1 --timescale 1ns/1ps"
ACCEL="rtl/periph/sync2ff.sv $A/async_fifo.sv $P1 $A/attn_seq.sv $A/axil_attn.sv"
fail=0

vl() {
  local top=$1; shift
  if verilator --lint-only -Wall $INC --top-module "$top" "$@" >/tmp/p2_accel_lint_$$.log 2>&1; then
    echo "verilator OK   $top"
  else
    echo "verilator FAIL $top"; cat /tmp/p2_accel_lint_$$.log; fail=1
  fi
}

vl async_fifo rtl/periph/sync2ff.sv $A/async_fifo.sv
vl async_fifo -GW=33 -GAW=3 rtl/periph/sync2ff.sv $A/async_fifo.sv
vl attn_seq $P1 $A/attn_seq.sv
vl axil_attn $ACCEL
vl obi2axil rtl/bus/obi2axil.sv
vl obi_decoder rtl/bus/obi_default_slave.sv rtl/bus/obi_decoder.sv
vl obi_decoder -GAXI_EN=1 rtl/bus/obi_default_slave.sv rtl/bus/obi_decoder.sv
vl soc_top $(cat rtl/core/core.f) \
  rtl/mem/dp_ram.sv rtl/bus/obi_default_slave.sv rtl/bus/obi_decoder.sv rtl/bus/apb_mux.sv \
  rtl/bus/obi2apb.sv rtl/bus/obi2axil.sv rtl/periph/sync_fifo.sv rtl/periph/uart_apb.sv \
  rtl/periph/gpio_apb.sv rtl/periph/timer_apb.sv rtl/periph/simctrl_apb.sv $ACCEL rtl/soc_top.sv
rm -f /tmp/p2_accel_lint_$$.log

if verible-verilog-lint --rules=line-length=length:100 $A/*.sv rtl/bus/obi2axil.sv \
     rtl/bus/obi_decoder.sv rtl/soc_top.sv formal/accel_fifo_top.sv; then
  echo "verible   OK   rtl/accel rtl/bus/obi2axil rtl/bus/obi_decoder rtl/soc_top formal/accel"
else
  echo "verible   FAIL"; fail=1
fi
exit $fail
