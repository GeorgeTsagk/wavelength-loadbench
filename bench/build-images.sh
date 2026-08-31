#!/usr/bin/env bash
# Build the two daemon images from the pinned local checkouts. The operator
# repo is private: source lives outside this repo and only the built image
# is used. Verifies the checkout is at the pinned revision before building,
# so an epoch can never silently run unpinned code (P14).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set -a; . "$HERE/config.env"; set +a

check_rev() {
  local src=$1 want=$2 got
  got=$(git -C "$src" rev-parse --short=8 HEAD)
  [[ "$got" == "$want" ]] || {
    echo "FATAL: $src is at $got, pinned $want" >&2; exit 1; }
  [[ -z "$(git -C "$src" status --porcelain)" ]] || {
    echo "FATAL: $src has uncommitted changes" >&2; exit 1; }
}

check_rev "$LUMOS_SRC" "$LUMOS_REV"
check_rev "$WAVELENGTH_SRC" "$WAVELENGTH_REV"

echo "building $LUMOS_IMAGE from $LUMOS_SRC @ $LUMOS_REV"
docker build -q -t "$LUMOS_IMAGE" "$LUMOS_SRC"

# wavewalletrpc+swapruntime enable the everyday wallet verbs (balance,
# recv, send) the workload drives; without the tags those RPCs don't exist.
echo "building $WAVED_IMAGE from $WAVELENGTH_SRC @ $WAVELENGTH_REV"
docker build -q -t "$WAVED_IMAGE" \
  --build-arg GOTAGS="wavewalletrpc swapruntime" "$WAVELENGTH_SRC"

echo "done"
