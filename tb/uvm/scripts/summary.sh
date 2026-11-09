#!/usr/bin/env bash
# Pass/fail and coverage table from run directories (each holds sim.log).
# Usage: summary.sh <run_dir>...   Exit 1 if any run failed or has no log.
# Coverage numbers are Verilator get_inst_coverage() per run; Verilator has
# no covergroup database merge, so no merged figure is printed.
set -uo pipefail
groups="cg_access cg_access.cx_reg_rw_be cg_b2b cg_gnt cg_wait cg_model cg_status cg_rx cg_misc"
printf '%-16s %-6s %7s %6s %5s' run result obi_req reads mism
for g in $groups; do printf ' %s' "${g#cg_}"; done; echo
npass=0; nfail=0
declare -A mn mx
for d in "$@"; do
  L="$d/sim.log"; name=$(basename "$d")
  if [ ! -f "$L" ]; then printf '%-16s %-6s (no log)\n' "$name" FAIL; nfail=$((nfail+1)); continue; fi
  if grep -q "P2UVM RESULT PASS" "$L" && ! grep -q "Assertion failed\|%Error\|UVM_FATAL @" "$L"; then res=PASS; npass=$((npass+1)); else res=FAIL; nfail=$((nfail+1)); fi
  nreq=$(sed -n 's/.*checked: obi_req=\([0-9]*\).*/\1/p' "$L" | tail -1)
  nrd=$(sed -n 's/.*reads=\([0-9]*\).*/\1/p' "$L" | tail -1)
  nmm=$(sed -n 's/.*mismatches: total=\([0-9]*\).*/\1/p' "$L" | tail -1)
  printf '%-16s %-6s %7s %6s %5s' "$name" "$res" "${nreq:--}" "${nrd:--}" "${nmm:--}"
  for g in $groups; do
    v=$(grep -o "COVERAGE $g [0-9.]*" "$L" | awk '{print $3}' | tail -1)
    printf ' %*s' "${#g}" "${v:--}"
    if [ -n "$v" ]; then
      [ -z "${mn[$g]:-}" ] && mn[$g]=$v && mx[$g]=$v
      mn[$g]=$(awk -v a="${mn[$g]}" -v b="$v" 'BEGIN{print (b<a)?b:a}')
      mx[$g]=$(awk -v a="${mx[$g]}" -v b="$v" 'BEGIN{print (b>a)?b:a}')
    fi
  done
  echo
done
echo "coverage range over runs (min..max %), per covergroup:"
for g in $groups; do [ -n "${mn[$g]:-}" ] && echo "  $g: ${mn[$g]} .. ${mx[$g]}"; done
echo "SUMMARY: $npass passed, $nfail failed (of $#)"
[ "$nfail" = 0 ]
