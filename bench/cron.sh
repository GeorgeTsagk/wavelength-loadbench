#!/usr/bin/env bash
# Cron entry point. Brings the network up if a reboot took it down, runs one
# epoch, refreshes the site, and commits. Designed to be safe to fire on a
# schedule with no one watching.
#
# Install with:
#   crontab -l 2>/dev/null | { cat; echo "17 */3 * * * /workspace/wavelength-loadbench/bench/cron.sh"; } | crontab -
#
# Every 3 hours. Epoch duration grows with accumulated state; if a run ever
# outgrows the interval the next firing waits for it and takes its turn, and
# a third firing exits immediately (see the two-lock scheme in epoch.sh).
set -uo pipefail

# cron gives a minimal environment. Everything this script shells out to has
# to be on PATH explicitly, and git needs HOME for the credential store.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/go/bin:$HOME/go/bin"
export HOME="${HOME:-$(getent passwd "$(id -u)" | cut -d: -f6)}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="$ROOT/logs/cron-$STAMP.log"
mkdir -p "$ROOT/logs"

exec > >(tee -a "$LOG") 2>&1

echo "=== cron run $STAMP ==="

# Stop when the series is complete. Removing the entry rather than returning
# early means the schedule stops firing instead of waking every 3 hours to
# decide there is nothing to do.
set -a; . "$HERE/config.env"; set +a
recorded=$(wc -l < "$ROOT/data/epochs.jsonl" 2>/dev/null || echo 0)
if [[ -n "${MAX_EPOCHS:-}" ]] && (( recorded >= MAX_EPOCHS )); then
  echo "series complete at $recorded epochs (limit $MAX_EPOCHS)"
  echo "removing the crontab entry; reinstall it to continue"
  crontab -l 2>/dev/null | grep -v "$HERE/cron.sh" | crontab -
  exit 0
fi

# A broken library once cost hours of silent failures; fail on that first.
"$HERE/selftest.sh" || { echo "selftest failed, aborting"; exit 1; }

# A host reboot leaves the containers stopped; deploy.sh is idempotent.
"$HERE/deploy.sh" || { echo "deploy failed, aborting"; exit 1; }

rc=0
"$HERE/epoch.sh" || rc=$?

"$HERE/report.sh" > "$ROOT/logs/report-$STAMP.txt" 2>&1 || true
cat "$ROOT/logs/report-$STAMP.txt"

"$HERE/render.sh" || echo "render failed (continuing)"

# Only ever commit the record, the site, and harness changes someone staged
# deliberately: data/ and docs/ here, nothing else. The lumos checkout and
# its patches live outside this repo entirely.
cd "$ROOT"
if [[ -n "$(git status --porcelain data docs 2>/dev/null)" ]]; then
  epoch=$(wc -l < data/epochs.jsonl)
  git add data docs
  git commit -q -m "data: epoch $epoch" || echo "nothing to commit"
  echo "committed epoch $epoch"
fi

# Push so the published page tracks the data. Never force, and never let a
# push failure lose the local commit: the record is already in the log.
if git remote get-url origin >/dev/null 2>&1; then
  git push origin HEAD || echo "push failed (commit is local, will go with the next run)"
fi

echo "=== cron run finished (epoch rc=$rc) ==="
exit "$rc"
