#!/usr/bin/env bash
# Run one benchmark epoch against the persistent wavebench regtest network
# and append one JSON record to data/epochs.jsonl.
#
# The network is never reset. Each epoch adds OOR chains, round history,
# mailbox traffic and indexer rows on top of everything prior epochs
# created, so the series measures how the operator and clients behave as
# their state grows, not one-shot throughput.
#
# Usage: bench/epoch.sh [--cases "send refresh"] [--dry-run]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set -a; . "$HERE/config.env"; set +a
. "$HERE/lib/common.sh"
. "$HERE/lib/metrics.sh"
. "$HERE/lib/cases.sh"

DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cases)   CASES="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done

DATA="$REPO_ROOT/data/epochs.jsonl"
LOCK="$REPO_ROOT/.bench.lock"
# CPU profile watchdog: a backstop for this script dying mid-case only.
WATCHDOG_S=$(awk -v t="$CASE_TIMEOUT" 'BEGIN{
  if (t ~ /m$/) { sub(/m$/, "", t); print t * 60 + 120 }
  else if (t ~ /h$/) { sub(/h$/, "", t); print t * 3600 + 120 }
  else { sub(/s$/, "", t); print t + 120 }
}')

# Two epochs must never overlap; two locks so at most one ever waits (P2).
# The outer lock is the queue slot: a second waiter has nothing to add.
exec 8>"$LOCK.wait"
flock -n 8 || { echo "an epoch is already queued, skipping this slot"; exit 0; }
exec 9>"$LOCK"
if ! flock -n 9; then
  echo "an epoch is running, waiting for it to finish"
  flock 9
fi
exec 8>&-

mkdir -p "$(dirname "$DATA")"
touch "$DATA"
EPOCH=$(( $(wc -l < "$DATA") + 1 ))

if [[ -n "${MAX_EPOCHS:-}" ]] && (( EPOCH > MAX_EPOCHS )); then
  echo "series complete: $((EPOCH - 1)) epochs recorded, limit is $MAX_EPOCHS"
  exit 0
fi

RUNDIR="$REPO_ROOT/logs/epoch-$(printf '%05d' "$EPOCH")"
mkdir -p "$RUNDIR"

log "epoch $EPOCH: cases='$CASES'"
log "health check"
health_check
ensure_operator_funded

# Untimed prerequisite: top up clients below the boarding floor. Recorded,
# so board cost renders as gaps in the series when nothing boarded.
BOARD_DETAIL="[]"
ensure_boarded

if (( DRY_RUN )); then
  log "dry run: prerequisites done, stopping before the timed cases"
  exit 0
fi

OPERATOR_VERSION=$(lumoscli info | jq -r .version)
CLIENT_VERSION=$(wavecli wb-client01 getinfo | jq -r .version)

log "collecting before snapshot"
BEFORE=$(snapshot)

STARTED=$(date -u +%FT%TZ)
T0=$(date +%s.%N)

CASE_RESULTS="[]"
for case_name in $CASES; do
  log "running case $case_name"
  type "case_$case_name" >/dev/null 2>&1 || die "no such case: $case_name"

  capture_all "$RUNDIR/pprof" "pre-$case_name"
  pg_stat_reset
  cpu_profile_start "$WATCHDOG_S"
  cpu0=$(case_cpu)

  c0=$(date +%s.%N)
  status=pass
  CASE_DETAIL="{}"
  "case_$case_name" || status=fail
  c1=$(date +%s.%N)
  dur=$(awk -v a="$c0" -v b="$c1" 'BEGIN{printf "%.2f", b-a}')

  cpu1=$(case_cpu)
  cpu_profile_stop "$RUNDIR/pprof" "$case_name"
  DB_MS=$(pg_total_exec_ms)
  pg_stat_top 15 > "$RUNDIR/pgstat-$case_name.json"
  capture_all "$RUNDIR/pprof" "post-$case_name"

  CASE_CPU=$(jq -cn --argjson a "$cpu0" --argjson b "$cpu1" \
    'reduce ($b | keys[]) as $k ({}; . + {($k): (($b[$k] // 0) - ($a[$k] // 0))})')

  log "  $case_name: $status in ${dur}s (db ${DB_MS}ms)"
  CASE_RESULTS=$(jq -cn --argjson acc "$CASE_RESULTS" --arg n "$case_name" \
    --arg s "$status" --argjson d "$dur" --argjson cpu "$CASE_CPU" \
    --argjson db_ms "${DB_MS:-null}" --argjson detail "$CASE_DETAIL" \
    '$acc + [{name: $n, status: $s, duration_s: $d, cpu_usec: $cpu,
              db_ms: $db_ms, detail: $detail}]')
done

T1=$(date +%s.%N)
TOTAL=$(awk -v a="$T0" -v b="$T1" 'BEGIN{printf "%.2f", b-a}')
FINISHED=$(date -u +%FT%TZ)

log "collecting after snapshot"
AFTER=$(snapshot)

ROUNDS=$(round_stats "$STARTED")
log "operator rounds this epoch: $(printf '%s' "$ROUNDS" | jq -c .)"

# Deterministic chain advance, outside every timed window. This is what
# ages batches toward the sweeper on a schedule the harness controls.
log "advancing chain by $MINE_BLOCKS_PER_EPOCH blocks"
mine_synced "$MINE_BLOCKS_PER_EPOCH" || true

# One more profile set at the epoch boundary, for cross-epoch diffs.
capture_all "$RUNDIR/pprof" "epoch"

# Per-epoch growth. Absolute sizes are dominated by fixed baselines; the
# delta is what compares.
DELTA=$(jq -cn --argjson b "$BEFORE" --argjson a "$AFTER" '
  {operator_pg_bytes:
     (if ($a.operator.pg.total != null and $b.operator.pg.total != null)
      then $a.operator.pg.total - $b.operator.pg.total else null end),
   clients_sqlite_bytes:
     ([ ($a.clients | keys[]) as $k |
        (($a.clients[$k].sqlite | values | add) // 0)
        - (($b.clients[$k].sqlite | values | add) // 0) ] | add),
   containers: (reduce (($a.containers // {}) | keys[]) as $k ({};
     . + { ($k): {
       cpu_usec: (($a.containers[$k].cpu_usec // 0) - ($b.containers[$k].cpu_usec // 0))
     }}))}')

RECORD=$(jq -cn \
  --argjson epoch "$EPOCH" \
  --arg started_at "$STARTED" \
  --arg finished_at "$FINISHED" \
  --argjson duration_s "$TOTAL" \
  --arg schema_note "$SCHEMA_NOTE" \
  --arg operator_version "$OPERATOR_VERSION" \
  --arg client_version "$CLIENT_VERSION" \
  --arg lumos_rev "$LUMOS_REV" \
  --arg wavelength_rev "$WAVELENGTH_REV" \
  --argjson config "$(jq -cn \
      --argjson send_total "$SEND_TOTAL" \
      --argjson send_waves "$SEND_WAVES" \
      --argjson send_min "$SEND_MIN" \
      --argjson send_max "$SEND_MAX" \
      --argjson num_clients "$NUM_CLIENTS" \
      --argjson blocks_per_epoch "$MINE_BLOCKS_PER_EPOCH" \
      '$ARGS.named')" \
  --argjson boards "$BOARD_DETAIL" \
  --argjson cases "$CASE_RESULTS" \
  --argjson before "$BEFORE" \
  --argjson after "$AFTER" \
  --argjson delta "$DELTA" \
  --argjson rounds "$ROUNDS" \
  '{epoch: $epoch, started_at: $started_at, finished_at: $finished_at,
    duration_s: $duration_s, schema_note: $schema_note,
    versions: {lumosd: $operator_version, waved: $client_version,
               lumos_rev: $lumos_rev, wavelength_rev: $wavelength_rev},
    config: $config, boards: $boards, cases: $cases,
    before: $before, after: $after, delta: $delta, rounds: $rounds}')

echo "$RECORD" >> "$DATA"
echo "$RECORD" | jq . > "$RUNDIR/record.json"

echo
echo "=== epoch $EPOCH summary ==="
echo "$RECORD" | jq -r '
  "duration: \(.duration_s)s   lumosd \(.versions.lumosd)   waved \(.versions.waved)   height \(.after.block_height)",
  "cases:",
  (.cases[] | "  \(.name): \(.status) \(.duration_s)s  db \(.db_ms)ms  \(.detail | tostring)"),
  "growth: operator pg +\(.delta.operator_pg_bytes)B  clients sqlite +\(.delta.clients_sqlite_bytes)B",
  "rounds: \(.rounds | tostring)"'

if echo "$CASE_RESULTS" | jq -e 'any(.[]; .status != "pass")' >/dev/null; then
  echo
  echo "one or more cases did not pass"
  exit 1
fi
