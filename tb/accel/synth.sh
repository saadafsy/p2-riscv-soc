#!/usr/bin/env bash
# Synthesis sanity (yosys generic synth): every new block synthesizes with
# no latches. axil_attn includes attention_top (about a minute).
set -uo pipefail
cd "$(dirname "$0")/../.."
OUT=tb/accel/build/synth
mkdir -p "$OUT"
A=rtl/accel
P1="$A/p1/mac_unit.sv $A/p1/matmul_tile.sv $A/p1/exp_lut_1p.sv $A/p1/sync_ram.sv
$A/p1/online_softmax.sv $A/p1/attention_top.sv"
fail=0

chk() {
  local top=$1; shift
  if yosys -q -l "$OUT/$top.log" -p "read_verilog -sv -DSYNTHESIS -I$A/p1 $*; synth -top $top; \
      select -assert-none t:\$dlatch t:\$adlatch t:\$dlatchsr t:\$_DLATCH*; \
      tee -q -o $OUT/$top.stat stat" >/dev/null 2>&1; then
    echo "synth OK (no latches) $top: $(awk '/cells$/ {print $1; exit}' $OUT/$top.stat) cells"
  else
    echo "synth FAIL $top (see $OUT/$top.log)"; fail=1
  fi
}
chk async_fifo rtl/periph/sync2ff.sv $A/async_fifo.sv
chk obi2axil   rtl/bus/obi2axil.sv
chk obi_decoder rtl/bus/obi_default_slave.sv rtl/bus/obi_decoder.sv
chk axil_attn  rtl/periph/sync2ff.sv $A/async_fifo.sv $P1 $A/attn_seq.sv $A/axil_attn.sv
exit $fail
