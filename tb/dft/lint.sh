#!/usr/bin/env bash
# Lint rtl/dft: verilator -Wall at the default and edge parameters, then
# verible (100 columns).
set -uo pipefail
cd "$(dirname "$0")/../.."
fail=0
log=$(mktemp)

vl() {
  if verilator --lint-only -Wall --top-module mbist_marchc "$@" rtl/dft/mbist_marchc.sv \
      >"$log" 2>&1; then
    echo "verilator OK   mbist_marchc $*"
  else
    echo "verilator FAIL mbist_marchc $*"; cat "$log"; fail=1
  fi
}

vl
vl -GAW=1 -GNBG=6
vl -GAW=30 -GNBG=1 -GBASE=32\'h4000_0000
rm -f "$log"

if verible-verilog-lint --rules=line-length=length:100 rtl/dft/*.sv; then
  echo "verible   OK   rtl/dft"
else
  echo "verible   FAIL"; fail=1
fi
exit $fail
