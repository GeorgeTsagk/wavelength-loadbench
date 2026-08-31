# shellcheck shell=bash
# The timed cases and the untimed boarding prerequisite. Sourced by epoch.sh.
#
# Each case_* function runs one case against the live network and writes
# per-operation NDJSON to $RUNDIR. It returns non-zero if the case failed.
# Case-level JSON detail is left in $CASE_DETAIL for epoch.sh to embed.

# One OOR send: fetch a fresh receive pubkey from the receiver (part of the
# real payment flow, so it belongs inside the timed window), submit the
# send, then poll the OOR session until it reaches a terminal state.
# `ark send oor` returns as soon as the intent is submitted, so the
# submission alone times nothing. Writes one NDJSON line; never fails the
# shell (the case aggregates).
one_oor_send() {
  local from=$1 to=$2 amount=$3 out=$4
  local t0 t1 status pk err="" sid sstat
  t0=$(date +%s.%N)
  pk=$(wavecli "$to" ark oor receive 2>/dev/null \
    | jq -r '.pubkey_xonly_hex // empty')
  if [[ -z "$pk" ]]; then
    status=recv_failed
  else
    err=$(wavecli "$from" ark send oor --pubkey "$pk" \
      --amount "$amount" --yes --timeout 60s 2>&1)
    sid=$(printf '%s' "$err" | jq -r '.session_id // empty' 2>/dev/null)
    if [[ -z "$sid" ]]; then
      status=fail
    else
      status=timeout
      local deadline=$(( $(date +%s) + 120 ))
      while (( $(date +%s) < deadline )); do
        sstat=$(wavecli "$from" ark oor get --session-id "$sid" 2>/dev/null \
          | jq -r '.session.status // .status // empty')
        case "$sstat" in
          *COMPLETED*) status=pass; break ;;
          *FAILED*)    status=fail
                       err=$(wavecli "$from" ark oor get --session-id "$sid" 2>/dev/null \
                         | jq -c '.session.failure_reason // .failure_reason // empty')
                       break ;;
        esac
        sleep 0.5
      done
    fi
  fi
  t1=$(date +%s.%N)
  jq -cn --arg from "$from" --arg to "$to" --argjson amount "$amount" \
    --arg status "$status" \
    --argjson duration_s "$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.3f", b-a}')" \
    --arg err "$(printf '%s' "$err" | tail -c 300)" \
    '{from: $from, to: $to, amount: $amount, status: $status,
      duration_s: $duration_s} + (if $status != "pass" and $err != "" then {err: $err} else {} end)' \
    >> "$out"
}

# SEND_TOTAL random client-to-client OOR sends in SEND_WAVES waves. Within a
# wave every client sends once, concurrently, to a uniformly random other
# client: concurrency spread across nodes, never stacked on one (P11). OOR is
# fully offchain, so this case needs no blocks.
case_send() {
  local out="$RUNDIR/send-results.ndjson"
  : > "$out"
  local per_wave=$(( SEND_TOTAL / SEND_WAVES ))
  local wave i from to amount pids
  local clients_arr=($CLIENTS)
  local n=${#clients_arr[@]}

  for wave in $(seq 1 "$SEND_WAVES"); do
    pids=()
    for i in $(seq 0 $(( per_wave - 1 ))); do
      from=${clients_arr[$(( i % n ))]}
      # Random receiver, never self.
      while :; do
        to=${clients_arr[$(( RANDOM % n ))]}
        [[ "$to" != "$from" ]] && break
      done
      amount=$(( SEND_MIN + RANDOM % (SEND_MAX - SEND_MIN + 1) ))
      one_oor_send "$from" "$to" "$amount" "$out" &
      pids+=($!)
    done
    local p
    for p in "${pids[@]}"; do wait "$p" || true; done
  done

  CASE_DETAIL=$(jq -sc '
    {sends: length,
     passed: [.[] | select(.status == "pass")] | length,
     failed: [.[] | select(.status != "pass")] | length,
     p50_s: (map(.duration_s) | sort | .[(length/2|floor)] // null),
     max_s: (map(.duration_s) | max // null),
     total_amount_sat: ([.[] | select(.status == "pass") | .amount] | add // 0)}' \
    "$out")
  [[ "$(jq -r .failed <<<"$CASE_DETAIL")" == 0 ]]
}

# True while a client has any round FSM in a non-terminal state.
client_round_active() {
  wavecli "$1" ark rounds list 2>/dev/null | jq -e '
    [.rounds[]? | select(.state != "ROUND_STATE_CONFIRMED"
                     and .state != "ROUND_STATE_FAILED")] | length > 0' \
    >/dev/null 2>&1
}

# True if any of the client's rounds ended failed in this window (round ids
# seen before the case are excluded by the caller via a baseline count).
client_failed_rounds() {
  wavecli "$1" ark rounds list 2>/dev/null | jq -r '
    [.rounds[]? | select(.state == "ROUND_STATE_FAILED")] | length' 2>/dev/null
}

# Refresh every client's full vtxo set. `refresh --all --yes` only queues
# the intent and auto-joins the next round, so submission is instant; the
# work happens in the shared round. All ten submissions land inside the
# operator's registration window, giving one 10-participant round. Rounds
# need a confirmation to reach their terminal state and nothing mines here
# except the harness, so the wait loop mines. Per-client duration is
# submit-to-terminal-round.
case_refresh() {
  local out="$RUNDIR/refresh-results.ndjson"
  : > "$out"
  declare -A t0 done_at failed_before submit_status
  local n now

  for n in $CLIENTS; do
    failed_before[$n]=$(client_failed_rounds "$n"); : "${failed_before[$n]:=0}"
    t0[$n]=$(date +%s.%N)
    if wavecli "$n" ark vtxos refresh --all --yes --timeout 60s \
        >/dev/null 2>&1; then
      submit_status[$n]=pending
    else
      submit_status[$n]=submit_failed
      done_at[$n]=$(date +%s.%N)
    fi
  done

  local deadline=$(( $(date +%s) + REFRESH_JOIN_TIMEOUT + 300 ))
  while :; do
    local waiting=0
    for n in $CLIENTS; do
      [[ "${submit_status[$n]}" == pending ]] || continue
      if [[ -z "${done_at[$n]:-}" ]] && ! client_round_active "$n"; then
        done_at[$n]=$(date +%s.%N)
      fi
      [[ -z "${done_at[$n]:-}" ]] && waiting=1
    done
    (( waiting )) || break
    if (( $(date +%s) > deadline )); then
      log "  refresh case deadline reached, abandoning wait"
      break
    fi
    mine_synced 1 >/dev/null 2>&1 || true
    sleep 2
  done

  for n in $CLIENTS; do
    local status=${submit_status[$n]} dur failed_now
    if [[ "$status" == pending ]]; then
      if [[ -z "${done_at[$n]:-}" ]]; then
        status=timeout; done_at[$n]=$(date +%s.%N)
      else
        failed_now=$(client_failed_rounds "$n"); : "${failed_now:=0}"
        if (( failed_now > ${failed_before[$n]} )); then
          status=round_failed
        else
          status=pass
        fi
      fi
    fi
    dur=$(awk -v a="${t0[$n]}" -v b="${done_at[$n]}" 'BEGIN{printf "%.3f", b-a}')
    jq -cn --arg node "$n" --arg status "$status" --argjson duration_s "$dur" \
      '{node: $node, status: $status, duration_s: $duration_s}' >> "$out"
  done

  CASE_DETAIL=$(jq -sc '
    {clients: length,
     passed: [.[] | select(.status == "pass")] | length,
     failed: [.[] | select(.status != "pass")] | length,
     p50_s: (map(.duration_s) | sort | .[(length/2|floor)] // null),
     max_s: (map(.duration_s) | max // null)}' "$out")
  [[ "$(jq -r .failed <<<"$CASE_DETAIL")" == 0 ]]
}

# Untimed prerequisite: top up any client whose offchain balance is under
# the floor. Sends coins to the client's boarding address, confirms them,
# then boards. Boarding completes through a round, so this also mines on
# demand. Returns JSON describing what it did via BOARD_DETAIL.
ensure_boarded() {
  local boarded="[]" n bal addr t0 t1 status
  for n in $CLIENTS; do
    bal=$(ark_balance "$n")
    [[ -n "$bal" ]] || { log "  WARNING: cannot read balance of $n"; continue; }
    (( bal >= BOARD_FLOOR )) && continue

    log "  boarding $n (balance $bal < $BOARD_FLOOR)"
    t0=$(date +%s.%N)
    status=pass
    addr=$(wavecli "$n" recv --onchain 2>/dev/null \
      | jq -r '.onchain_address // empty')
    if [[ -z "$addr" ]]; then
      status=addr_failed
    else
      btc -rpcwallet=miner sendtoaddress "$addr" \
        "$(awk -v s="$BOARD_AMOUNT" 'BEGIN{printf "%.8f", s/1e8}')" >/dev/null
      # recv --onchain registers a deposit entry that the daemon boards by
      # itself once the funding tx confirms, so the only work left is to
      # mine until the offchain balance reflects it. `ark board` fires the
      # same path as a belt-and-braces trigger.
      mine_synced 1
      wavecli "$n" ark board --timeout 120s >/dev/null 2>&1 || true
      if ! mine_until 300 board_done "$n" "$bal"; then
        status=timeout
      fi
    fi
    t1=$(date +%s.%N)
    boarded=$(jq -cn --argjson acc "$boarded" --arg n "$n" --arg s "$status" \
      --argjson bal "$bal" \
      --argjson d "$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f", b-a}')" \
      '$acc + [{node: $n, status: $s, balance_before_sat: $bal, duration_s: $d}]')
    [[ "$status" == pass ]] || log "  WARNING: boarding $n: $status"
  done
  BOARD_DETAIL="$boarded"
}

# Condition for mine_until during boarding: the offchain balance moved
# above where it started.
board_done() {
  local n=$1 before=$2 now
  now=$(ark_balance "$n")
  [[ -n "$now" ]] && (( now > before ))
}
