#!/usr/bin/env bash
# Measure what the harness's own profiling costs, instead of assuming it is
# cheap. Runs a fixed offchain workload (waves of 10 concurrent OOR sends)
# under three configurations: profiling off, profiling on (block+mutex
# rates from config.env plus an active CPU profile bracket, exactly like an
# epoch), then off again so drift between the two controls is visible.
#
# Recreates the daemon containers per configuration (the rates are startup
# flags), so run this against a network whose state you are willing to
# perturb; it moves sats between clients but never touches the chain.
# Results are appended to data/profiling-overhead.txt.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set -a; . "$HERE/config.env"; set +a
. "$HERE/lib/common.sh"
. "$HERE/lib/metrics.sh"

REPS=${REPS:-3}
WAVES_PER_REP=${WAVES_PER_REP:-3}
AMOUNT=30000
OUT="$REPO_ROOT/data/profiling-overhead.txt"

reconfigure() {
  local block=$1 mutex=$2
  log "recreating daemons with blockrate=$block mutexfraction=$mutex"
  BLOCK_PROFILE_RATE=$block MUTEX_PROFILE_FRACTION=$mutex \
    bash "$HERE/gen-compose.sh" >/dev/null
  $COMPOSE up -d >/dev/null 2>&1
  local n
  for n in $CLIENTS; do
    for _ in $(seq 1 60); do
      [[ "$(wavecli "$n" getinfo 2>/dev/null \
        | jq -r '.wallet_state // empty')" == *READY* ]] && break
      sleep 2
    done
  done
  lumoscli info >/dev/null || die "lumosd not ready after reconfigure"
}

# One wave of 10 concurrent round-robin sends; prints nothing, fails never.
wave() {
  local clients_arr=($CLIENTS) i pids=()
  local n=${#clients_arr[@]}
  for i in $(seq 0 $(( n - 1 ))); do
    (
      pk=$(wavecli "${clients_arr[$(( (i + 1) % n ))]}" ark oor receive \
        --timeout 60s 2>/dev/null | jq -r '.pubkey_xonly_hex // empty')
      [[ -n "$pk" ]] && wavecli "${clients_arr[$i]}" ark send oor \
        --pubkey "$pk" --amount "$AMOUNT" --yes --timeout 120s \
        >/dev/null 2>&1
    ) &
    pids+=($!)
  done
  local p; for p in "${pids[@]}"; do wait "$p" || true; done
}

run_config() {
  local label=$1 cpu_bracket=$2
  local rep t0 t1 c0 c1 wall cpu
  for rep in $(seq 1 "$REPS"); do
    [[ "$cpu_bracket" == yes ]] && cpu_profile_start 600
    c0=$(case_cpu)
    t0=$(date +%s.%N)
    for _ in $(seq 1 "$WAVES_PER_REP"); do wave; done
    t1=$(date +%s.%N)
    c1=$(case_cpu)
    [[ "$cpu_bracket" == yes ]] && cpu_profile_stop /tmp overhead
    wall=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f", b-a}')
    cpu=$(jq -cn --argjson a "$c0" --argjson b "$c1" \
      '{lumosd: (($b["wb-lumosd"] - $a["wb-lumosd"]) / 1e6),
        client01: (($b["wb-client01"] - $a["wb-client01"]) / 1e6)}')
    jq -cn --arg label "$label" --argjson rep "$rep" \
      --argjson wall_s "$wall" --argjson cpu_s "$cpu" \
      --arg at "$(date -u +%FT%TZ)" \
      '{at: $at, config: $label, rep: $rep, wall_s: $wall_s, cpu_s: $cpu_s}' \
      | tee -a "$OUT"
  done
}

log "profiling overhead: $REPS reps x $WAVES_PER_REP waves of 10 sends per config"
reconfigure 0 0
run_config off-1 no
reconfigure "$BLOCK_PROFILE_RATE" "$MUTEX_PROFILE_FRACTION"
run_config on yes
reconfigure 0 0
run_config off-2 no

# Restore the standard profiling-on compose for normal operation.
bash "$HERE/gen-compose.sh" >/dev/null
$COMPOSE up -d >/dev/null 2>&1

jq -s '
  group_by(.config) | map({
    config: .[0].config,
    mean_wall_s: ((map(.wall_s) | add) / length * 100 | round / 100),
    mean_lumosd_cpu_s: ((map(.cpu_s.lumosd) | add) / length * 100 | round / 100),
    mean_client01_cpu_s: ((map(.cpu_s.client01) | add) / length * 100 | round / 100)
  })' < <(tail -n $(( REPS * 3 )) "$OUT")
