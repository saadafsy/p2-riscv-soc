#!/usr/bin/env bash
# Build every ISA test and C program into build/sw/<name>/.
#   scripts/build_sw.sh          build
#   scripts/build_sw.sh --run    build, then run each program on the ISS (exit 1 on any fail)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$HOME/tools/riscv/bin:$PATH"
PY="${PYTHON:-python3}"

make -C "$ROOT/sw" -j"$(nproc)" all

if [[ "${1:-}" == "--run" ]]; then
  fails=0
  for hex in "$ROOT"/build/sw/*/*.hex; do
    name="$(basename "$hex" .hex)"
    [[ "$name" == rand_* ]] && continue
    if out="$("$PY" "$ROOT/model/rv32_iss.py" "$hex" 2>&1)"; then
      echo "PASS $name: $(tail -n1 <<<"$out")"
    else
      echo "FAIL $name:"; echo "$out" | sed 's/^/    /'
      fails=$((fails + 1))
    fi
  done
  echo "ISS: $fails failing program(s)"
  [[ $fails -eq 0 ]]
fi
