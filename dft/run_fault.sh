#!/usr/bin/env bash
# Scan-chain insertion and stuck-at ATPG for one block, on a sky130_fd_sc_hd
# gate netlist, with the tools in the Fault image (ghcr.io/aucohl/fault):
#   1. yosys (host): synthesize to sky130 cells, flattened, plain D flops only
#   2. gen_cells.py: behavioral models of the cells used, from the liberty
#   3. fault cut:   flip-flops become pseudo inputs/outputs (full-scan view)
#   4. nl2bench + quaigh atpg: SAT-based stuck-at pattern generation with
#      compaction; coverage over all collapsed input/output stuck-at faults
#   5. fault chain: every flop gets a scan mux, one chain is stitched with
#      boundary cells on the ports, and the chain is checked in simulation
# Fault's own `atpg` crashes in image 0.9.4 (SIGILL even on its bundled
# ISCAS benchmarks), hence quaigh for step 4.
# Usage: bash dft/run_fault.sh <top> <clock> <reset> [active_low] -- <rtl files>
# Outputs in build/dft/<top>/: netlists (.nl, .cut, .chained), patterns
# (.test), atpg.log with the coverage line, chain.log.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
top=$1; clk=$2; rst=$3; shift 3
lowflag=()
if [[ "${1:-}" == active_low ]]; then lowflag=(--reset-active-low); shift; fi
[[ "${1:-}" == -- ]] && shift
LIB="${LIB:-$HOME/tools/lib/sky130_fd_sc_hd__tt_025C_1v80.lib}"
YOSYS="${YOSYS:-$HOME/oss-cad-suite/bin/yosys}"
# docker on PATH if it reaches a daemon, else Docker Desktop's CLI from WSL.
if [[ -z "${DOCKER:-}" ]]; then
  DOCKER=/mnt/c/Users/Owner/AppData/Local/Programs/DockerDesktop/resources/bin/docker.exe
  if command -v docker >/dev/null && docker version >/dev/null 2>&1; then DOCKER=docker; fi
fi
IMAGE="${IMAGE:-ghcr.io/aucohl/fault:latest}"
OUT="$ROOT/build/dft/$top"
rm -rf "$OUT"; mkdir -p "$OUT"
cd "$ROOT"

"$YOSYS" -q -l "$OUT/synth.log" -p "
  read_verilog -sv -DSYNTHESIS $*;
  synth -flatten -top $top;
  dfflegalize -cell \$_DFF_P_ 01;
  dfflibmap -liberty $LIB;
  abc -liberty $LIB;
  hilomap -singleton -hicell sky130_fd_sc_hd__conb_1 HI -locell sky130_fd_sc_hd__conb_1 LO;
  opt_clean -purge;
  tee -o $OUT/synth_stat.txt stat -liberty $LIB;
  write_verilog -noattr -noexpr -nohex -nodec $OUT/$top.nl.v"
python3 "$ROOT/dft/gen_cells.py" "$LIB" "$OUT/$top.nl.v" "$OUT/cells.v"
cp "$LIB" "$OUT/cells.lib"
cp "$ROOT/dft/sky130_config.yml" "$OUT/config.yml"

name="fault_${top}_$$"
trap '"$DOCKER" rm -f "$name" >/dev/null 2>&1 || true' EXIT
common="--clock $clk --reset $rst ${lowflag[*]}"
"$DOCKER" create --name "$name" -w /work "$IMAGE" bash -c "
  set -o pipefail
  fault cut -s config.yml $common -o $top.cut.v $top.nl.v > cut.log 2>&1 || { tail cut.log; exit 1; }
  nl2bench -l cells.lib -o $top.bench $top.cut.v > bench.log 2>&1 || { tail bench.log; exit 2; }
  quaigh atpg $top.bench -o $top.test 2>&1 | tr '\r' '\n' | grep -v progress > atpg.log || { tail atpg.log; exit 3; }
  fault chain -l cells.lib -c cells.v -s config.yml $common -o $top.chained.v $top.nl.v > chain.log 2>&1
  echo chain_rc=\$? >> chain.log
  grep -E 'Analyzing|Kept' atpg.log; grep -E 'chain length|Length|chain_rc|rror' chain.log" > /dev/null
tar -C "$OUT" --transform 's,^\./,work/,' -cf - . | "$DOCKER" cp - "$name:/"
set +e
"$DOCKER" start -a "$name"
rc=$?
set -e
"$DOCKER" cp "$name:/work/." - | tar -x -C "$OUT"
echo "dft $top rc=$rc (outputs in build/dft/$top)"
exit $rc
