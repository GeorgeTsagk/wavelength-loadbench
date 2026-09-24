#!/usr/bin/env bash
# Build the operator's lnd from the exact commit lumos pins.
#
# lumos calls FundPsbt with InputReleaseAfterSpendConfs and then verifies
# the wallet echoed the requested depth back on every lease. That field is
# not in lnd master, only on the branch lumos depends on, so no published
# lnd image works: rounds fail with "wallet did not accept the requested
# release-after-spend depth". The Dockerfile in the lnd tree clones from
# GitHub, which cannot reach an unmerged commit, so this builds from the
# local checkout instead.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set -a; . "$HERE/config.env"; set +a

got=$(git -C "$LND_SRC" rev-parse --short=9 HEAD)
[[ "$got" == "$LND_REV" ]] || {
  echo "FATAL: $LND_SRC is at $got, pinned $LND_REV" >&2; exit 1; }

echo "building $LND_IMAGE from $LND_SRC @ $LND_REV"
docker build -q -f "$LND_SRC/wavebench.Dockerfile" -t "$LND_IMAGE" "$LND_SRC"
