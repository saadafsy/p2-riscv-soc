#!/usr/bin/env bash
# Compile (cached) and run the APB subsystem UVM bench under Verilator with
# Accellera UVM 1800.2-2017-1.0 ($UVM_HOME), +define+UVM_NO_DPI.
# Usage: run.sh <test> <seed> <outdir> [--bug strb|proto|obi] [+plusargs...]
# One build per bug variant under tb/uvm/build/obj_<variant>; rebuilt when
# any tb/uvm or RTL source is newer than the binary.
set -euo pipefail
test_name=${1:?test}; seed=${2:?seed}; outdir=${3:?outdir}; shift 3
here=$(cd "$(dirname "$0")/.." && pwd)          # tb/uvm
root=$(cd "$here/../.." && pwd)                 # repo
export PATH="$HOME/oss-cad-suite/bin:$HOME/tools/verible/bin:$PATH"
UVM_HOME=${UVM_HOME:-$HOME/tools/uvm/1800.2-2017-1.0/src}
JOBS=${JOBS:-4}
[ -f "$UVM_HOME/uvm_pkg.sv" ] || { echo "run.sh: UVM_HOME=$UVM_HOME has no uvm_pkg.sv" >&2; exit 2; }
variant=base; defines=(); plusargs=()
while [ $# -gt 0 ]; do
  case "$1" in
    --bug)
      variant=bug_$2
      case "$2" in
        strb)  defines+=(+define+INJECT_BUG_STRB) ;;
        proto) defines+=(+define+INJECT_BUG_PROTO) ;;
        obi)   defines+=(+define+INJECT_BUG_OBI) ;;
        *) echo "run.sh: unknown bug '$2'" >&2; exit 2 ;;
      esac
      shift 2 ;;
    *) plusargs+=("$1"); shift ;;
  esac
done
obj="$here/build/obj_$variant"
rtl=("$root/rtl/bus/obi2apb.sv" "$root/rtl/bus/apb_mux.sv"
     "$root/rtl/bus/obi_checker.sv" "$root/rtl/bus/apb_checker.sv"
     "$root/rtl/periph/sync2ff.sv" "$root/rtl/periph/sync_fifo.sv"
     "$root/rtl/periph/uart_apb.sv" "$root/rtl/periph/gpio_apb.sv"
     "$root/rtl/periph/timer_apb.sv" "$root/rtl/periph/simctrl_apb.sv")
tb=("$here/obi_if.sv" "$here/apb_if.sv" "$here/apb_sub_wrap.sv" "$here/apb_sub_binds.sv"
    "$here/p2_uvm_pkg.sv" "$here/tb_top.sv")
mkdir -p "$outdir" "$here/build"
stale=0
if [ ! -x "$obj/Vtb_top" ]; then stale=1
elif [ -n "$(find "$root/rtl/bus" "$root/rtl/periph" "$here" -maxdepth 1 \( -name '*.sv' -o -name '*.vlt' \) -newer "$obj/Vtb_top" | head -1)" ]; then stale=1; fi
if [ "$stale" = 1 ]; then
  echo "run.sh: building $variant (verilator -j $JOBS)"
  # --coverage-user: covergroup bins go to coverage.dat (mergeable across
  # seeds with verilator_coverage); line/toggle only on RTL (cov_off.vlt).
  ( cd "$here" && verilator -Wno-fatal --binary --assert -j "$JOBS" --top-module tb_top --Mdir "$obj" \
      --coverage-user --coverage-line --coverage-toggle "$here/cov_off.vlt" \
      "+incdir+$UVM_HOME" +define+UVM_NO_DPI "${defines[@]}" "+incdir+$here" \
      "$UVM_HOME/uvm_pkg.sv" "${rtl[@]}" "${tb[@]}" ) > "$here/build/compile_$variant.log" 2>&1 \
    || { echo "run.sh: compile failed, see $here/build/compile_$variant.log" >&2; tail -30 "$here/build/compile_$variant.log" >&2; exit 2; }
fi
cd "$outdir"
set +e
"$obj/Vtb_top" "+UVM_TESTNAME=$test_name" "+verilator+seed+$seed" +UVM_VERBOSITY=UVM_LOW \
  "${plusargs[@]}" > sim.log 2>&1
rc=$?
set -e
echo "run.sh: exit=$rc test=$test_name seed=$seed variant=$variant log=$outdir/sim.log"
exit $rc
