#!/usr/bin/env bash
# Open-source place-and-route of the Basys 3 board top (fpga/basys3_top.sv:
# SoC at 62.5 MHz and accelerator at 50 MHz, both from one MMCM) with the openXC7 flow:
#   yosys synth_xilinx -> nextpnr-himbaechel (xilinx, Project X-Ray chipdb)
#   -> fasm2frames -> xc7frames2bit
# Usage:  bash fpga/openxc7/build.sh [firmware.hex]   (default build/sw/hello/hello.hex)
# Env: OPENXC7 (default ~/tools/openxc7), YOSYS, SEED (1), THREADS (6),
#   OUT (build/openxc7), ACCEL (0 default; 1 = include the attention
#   accelerator, ACCEL_EN = 1).
# With ACCEL=1 the 16 MAC units' 8x8 multipliers are mapped to LUTs (yosys
# booth) so the build uses 72 of the XC7A35T's 90 DSP48 slices instead of 88;
# at 98% DSP use nextpnr did not finish routing.
# nextpnr reads only PACKAGE_PIN, IOSTANDARD and create_clock, so the board
# XDC is filtered to those lines; the MMCM output clock is derived by nextpnr.
# Paths between the two clocks are not timed (nextpnr reports them as
# cross-domain); they only exist in the gray-pointer FIFOs and synchronizers.
# Produces a bitstream only; nothing here touches a board.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OPENXC7="${OPENXC7:-$HOME/tools/openxc7}"
YOSYS="${YOSYS:-$HOME/oss-cad-suite/bin/yosys}"
SEED="${SEED:-1}"
OUT="${OUT:-$ROOT/build/openxc7}"
HEX="$(realpath "${1:-$ROOT/build/sw/hello/hello.hex}")"
PART=xc7a35tcpg236-1
DIE=xc7a50t
FAMILY=artix7
TOP=basys3_top

# shellcheck disable=SC1091
source "$OPENXC7/export.sh"
DB="$PRJXRAY_DB_DIR"
CHIPDB="$OPENXC7/share/nextpnr/himbaechel/xilinx/chipdb-$DIE.bin"
[[ -s "$CHIPDB" ]] || { echo "missing $CHIPDB (generate it with the P1 kit's build.sh)"; exit 1; }
[[ -s "$HEX" ]] || { echo "missing firmware $HEX (make sw)"; exit 1; }
mkdir -p "$OUT"
cd "$ROOT"

# Only port-based clocks: the BSCANE2 TCK clock (get_pins) is Vivado-only.
grep -E '^\s*(set_property .*(PACKAGE_PIN|IOSTANDARD)|create_clock .*get_ports)' fpga/basys3.xdc \
  > "$OUT/basys3_pnr.xdc"

# rtl/soc.f: everything outside the core, soc_top last.
mapfile -t CORE < rtl/core/core.f
mapfile -t SOC < rtl/soc.f
SRCS=("${CORE[@]}" "${SOC[@]}" fpga/basys3_top.sv)

# FPGA_XC7 selects BSCANE2 (JTAG on the USB cable) and BUFGCE (accelerator
# clock gate).
ACCEL_STEPS=""
if [[ "${ACCEL:-0}" == 1 ]]; then
  ACCEL_STEPS="chparam -set ACCEL_EN 1 $TOP; hierarchy -top $TOP; proc; booth mac_unit;"
fi
echo "== yosys ($("$YOSYS" -V)), ACCEL=${ACCEL:-0}"
"$YOSYS" -q -l "$OUT/synth.log" -p "
  read_verilog -sv -DSYNTHESIS -DFPGA_XC7 -I$ROOT/rtl/accel/p1 ${SRCS[*]};
  chparam -set INIT_FILE \"$HEX\" $TOP;
  $ACCEL_STEPS
  synth_xilinx -flatten -abc9 -arch xc7 -top $TOP;
  tee -o $OUT/synth_stat.txt stat;
  write_json $OUT/$TOP.json"

echo "== nextpnr-himbaechel (xilinx)"
nextpnr-himbaechel --chipdb "$CHIPDB" --device "$PART" --json "$OUT/$TOP.json" \
  -o xdc="$OUT/basys3_pnr.xdc" -o fasm="$OUT/$TOP.fasm" --router router2 --seed "$SEED" \
  --threads "${THREADS:-6}" --timing-allow-fail --report "$OUT/report.json" --log "$OUT/pnr.log"

echo "== fasm2frames + xc7frames2bit"
fasm2frames --part "$PART" --db-root "$DB/$FAMILY" "$OUT/$TOP.fasm" "$OUT/$TOP.frames"
xc7frames2bit --part_file "$DB/$FAMILY/$PART/part.yaml" --part_name "$PART" \
  --frm_file "$OUT/$TOP.frames" --output_file "$OUT/$TOP.bit"

{
  echo "openXC7 build of $TOP for $PART (Basys 3), seed $SEED, ACCEL=${ACCEL:-0}, firmware $(basename "$HEX")"
  echo "yosys: $("$YOSYS" -V)"
  echo "nextpnr: $(nextpnr-himbaechel --version 2>&1 | head -1)"
  echo "--- post-route timing (last report per clock)"
  grep -E "Max frequency for clock" "$OUT/pnr.log" | sed 's/^[A-Za-z]*: *//' | awk '{c[$5]=$0} END {for (k in c) print c[k]}'
  echo "--- utilisation"
  sed -n '/Device utilisation:/,/^Info: *$/p' "$OUT/pnr.log" | grep -E ' [1-9][0-9]*/ *[0-9]+' || true
  echo "--- bitstream"
  ls -l "$OUT/$TOP.bit"
  if grep -q "FAIL at" "$OUT/pnr.log"; then echo "TIMING: FAILED"; else echo "TIMING: met"; fi
  echo "NOT run on a board: the bitstream is untested on hardware."
} | tee "$OUT/summary.txt"
