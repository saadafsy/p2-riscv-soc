#!/usr/bin/env bash
# Place-and-route one block with OpenROAD-flow-scripts (sky130hd) in the
# openroad/orfs Docker image: synthesis, floorplan, placement, CTS, global and
# detailed routing, parasitic extraction, signoff STA, GDS.
# Usage: bash pd/run_orfs.sh <design>   (a directory under pd/ with config.mk)
# Env: DOCKER (docker CLI, default docker or Docker Desktop's docker.exe),
#      IMAGE (default openroad/orfs:latest), NUM_CORES (default 8).
# The repo is copied into the container (no bind mount needed); results come
# back to build/orfs/<design>/ (logs, reports, results incl. 6_final.gds).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
design="${1:?usage: run_orfs.sh <design>}"
[[ -f "$ROOT/pd/$design/config.mk" ]] || { echo "no pd/$design/config.mk"; exit 1; }
DOCKER="${DOCKER:-$(command -v docker || echo /mnt/c/Users/Owner/AppData/Local/Programs/DockerDesktop/resources/bin/docker.exe)}"
IMAGE="${IMAGE:-openroad/orfs:latest}"
name="orfs_${design}_$$"
out="$ROOT/build/orfs"
mkdir -p "$out"
trap '"$DOCKER" rm -f "$name" >/dev/null 2>&1 || true' EXIT

"$DOCKER" create --name "$name" -w /OpenROAD-flow-scripts/flow "$IMAGE" bash -c "
  source /OpenROAD-flow-scripts/env.sh >/dev/null
  mkdir -p /work/build/orfs
  make DESIGN_CONFIG=/work/pd/$design/config.mk WORK_HOME=/work/build/orfs/$design \
       NUM_CORES=${NUM_CORES:-8} 2>&1 | tee /work/build/orfs/$design.log
  rc=\${PIPESTATUS[0]}
  make DESIGN_CONFIG=/work/pd/$design/config.mk WORK_HOME=/work/build/orfs/$design metadata > /dev/null 2>&1 || true
  exit \$rc" > /dev/null
tar -C "$ROOT" --transform 's,^,work/,' -cf - rtl pd | "$DOCKER" cp - "$name:/"
set +e
"$DOCKER" start -a "$name" > /dev/null
rc=$?
set -e
rm -rf "$out/$design"
"$DOCKER" cp "$name:/work/build/orfs/." - | tar -x -C "$out"
echo "ORFS $design rc=$rc (results in build/orfs/$design)"
exit $rc
