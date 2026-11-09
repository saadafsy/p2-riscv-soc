#!/usr/bin/env bash
# Synthesis sanity (yosys generic synth). The new blocks must have no
# latches. clk_gate's behavioral model must give exactly one latch (the ICG
# latch, by design) and none with the sky130 cell. soc_top as a whole: exactly
# one latch (that ICG) with the behavioral model, none with the sky130 cell.
# Latches are inferred by proc, so synthesis stops before the fine
# (technology-mapping) stage; that also keeps the 64 KB RAM as a memory.
set -uo pipefail
cd "$(dirname "$0")/../.."
OUT=tb/socdbg/build/synth
mkdir -p "$OUT"
S=tb/socdbg/stubs
SOC="$(cat rtl/core/core.f | tr '\n' ' ') $(cat rtl/soc.f | tr '\n' ' ')"
fail=0

# chk <name> <expected latches> <top> <defines> <files...>
chk() {
  local name=$1 want=$2 top=$3 defs=$4; shift 4
  if ! yosys -q -l "$OUT/$name.log" -p "read_verilog -sv -DSYNTHESIS $defs -Irtl/accel/p1 $*; \
      synth -top $top -flatten -run begin:fine; select -count t:\$dlatch t:\$adlatch t:\$dlatchsr t:\$_DLATCH*; \
      tee -q -o $OUT/$name.stat stat" >/dev/null 2>&1; then
    echo "synth FAIL $name (see $OUT/$name.log)"; fail=1; return
  fi
  local got
  got=$(grep -oE '^[0-9]+ objects' "$OUT/$name.log" | tail -1 | awk '{print $1}')
  if [ "${got:-x}" = "$want" ]; then
    echo "synth OK   $name: $got latch(es), as expected"
  else
    echo "synth FAIL $name: ${got:-?} latch(es), expected $want"; fail=1
  fi
}

chk obi_arb2      0 obi_arb2     "" rtl/bus/obi_arb2.sv
chk bist_ram_mux  0 bist_ram_mux "" rtl/dft/bist_ram_mux.sv
chk sysctl_apb    0 sysctl_apb   "" rtl/periph/sync2ff.sv rtl/periph/sysctl_apb.sv
chk mbist_marchc  0 mbist_marchc "" rtl/dft/mbist_marchc.sv
chk clk_gate      1 clk_gate     "" rtl/clk/clk_gate.sv
chk clk_gate_sky  0 clk_gate     "-DSKY130" $S/sky130_icg.sv rtl/clk/clk_gate.sv
# shellcheck disable=SC2086
chk soc_top       1 soc_top      "" $SOC
# shellcheck disable=SC2086
chk soc_top_sky   0 soc_top      "-DSKY130" $S/sky130_icg.sv $SOC
exit $fail
