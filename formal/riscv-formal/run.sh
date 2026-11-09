#!/usr/bin/env bash
# Run the riscv-formal checks (github.com/YosysHQ/riscv-formal) on rv32_core.
# Usage: bash formal/riscv-formal/run.sh [make args, e.g. -j8 or a check name]
# RVF (default ~/tools/riscv-formal) is a clone of riscv-formal; this script
# copies the wrapper, config and core RTL into $RVF/cores/p2core, generates the
# checks there and runs them. Summary: build/riscv-formal/summary.txt.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RVF="${RVF:-$HOME/tools/riscv-formal}"
CORE="$RVF/cores/${CORE_NAME:-p2core}"
rm -rf "$CORE"; mkdir -p "$CORE/rtl"
cp "$ROOT/formal/riscv-formal/wrapper.sv" "$CORE/"
files=""
while read -r f; do
  [[ "$f" =~ ^[[:space:]]*(#|//|$) ]] && continue
  cp "$ROOT/$f" "$CORE/rtl/"
  files+="@basedir@/cores/@core@/rtl/$(basename "$f")"$'\n'
done < "$ROOT/rtl/core/core.f"
# checks.cfg lists the core files through the @CORE_FILES@ placeholder.
awk -v f="$files" '{ if ($0 == "@CORE_FILES@") printf "%s", f; else print }' \
  "${RVF_CFG:-$ROOT/formal/riscv-formal/checks.cfg}" > "$CORE/checks.cfg"
cd "$CORE"
python3 ../../checks/genchecks.py
set +e
make -C checks -k "${@:--j8}" > checks.log 2>&1
set -e
out="$ROOT/build/riscv-formal/${CORE_NAME:-p2core}"; mkdir -p "$out"
{
  echo "riscv-formal $(git -C "$RVF" log -1 --format=%h) on rv32_core, $(date -I)"
  for d in checks/*/; do
    n=$(basename "$d")
    if [[ -f "$d/PASS" ]]; then echo "PASS $n"
    elif [[ -f "$d/FAIL" ]]; then echo "FAIL $n"
    elif [[ -f "$d/ERROR" ]]; then echo "ERROR $n"
    else echo "UNKNOWN $n"; fi
  done | sort
} > "$out/summary.txt"
cp checks.log "$out/"
grep -c ^PASS "$out/summary.txt" | sed 's/^/passed: /'
grep -v ^PASS "$out/summary.txt" | tail -n +2 || true
