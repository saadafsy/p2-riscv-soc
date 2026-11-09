#!/usr/bin/env bash
# Synthesis sanity: dp_ram (AW=14) must map to block RAM under synth_xilinx;
# every bus/periph block must synthesize with no latches.
set -uo pipefail
cd "$(dirname "$0")/../.."
OUT=tb/periph/build/synth
mkdir -p "$OUT"
B=rtl/bus; P=rtl/periph; M=rtl/mem
fail=0

yosys -q -l "$OUT/dp_ram_xc7.log" -p "read_verilog -sv $M/dp_ram.sv; \
  chparam -set AW 14 dp_ram; synth_xilinx -family xc7 -top dp_ram; \
  tee -o $OUT/dp_ram_xc7.stat stat" >/dev/null || fail=1
r36=$(awk '$2 == "RAMB36E1" {print $1}' "$OUT/dp_ram_xc7.stat"); r36=${r36:-0}
r18=$(awk '$2 == "RAMB18E1" {print $1}' "$OUT/dp_ram_xc7.stat"); r18=${r18:-0}
luts=$(awk '$2 ~ /^LUT[1-6]$/ {s += $1} END {print s + 0}' "$OUT/dp_ram_xc7.stat")
echo "dp_ram AW=14 xc7: RAMB36E1=$r36 RAMB18E1=$r18 LUTs=$luts"
# 2^14 x 32 bit = 512 Kbit = 16 RAMB36
if [ "$r36" -ne 16 ] || [ "$r18" -ne 0 ]; then echo "FAIL: expected 16 RAMB36E1"; fail=1; fi

chk() {
  local top=$1; shift
  if yosys -q -l "$OUT/$top.log" -p "read_verilog -sv -DSYNTHESIS $*; synth -top $top; \
      select -assert-none t:\$dlatch t:\$adlatch t:\$dlatchsr t:\$_DLATCH*" >/dev/null 2>&1; then
    echo "synth OK (no latches) $top"
  else
    echo "synth FAIL $top (see $OUT/$top.log)"; fail=1
  fi
}
chk uart_apb    $P/sync2ff.sv $P/sync_fifo.sv $P/uart_apb.sv
chk gpio_apb    $P/sync2ff.sv $P/gpio_apb.sv
chk timer_apb   $P/timer_apb.sv
chk simctrl_apb $P/simctrl_apb.sv
chk obi2apb     $B/apb_mux.sv $B/obi2apb.sv
chk obi_decoder $B/obi_default_slave.sv $B/obi_decoder.sv
exit $fail
