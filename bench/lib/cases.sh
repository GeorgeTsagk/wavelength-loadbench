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
  local t0 t1 status pk err="" sid sstat recv_before recv_after
  t0=$(date +%s.%N)
  # Receiver balance before, so delivery can be verified rather than
  # assumed from the sender's view.
  recv_before=$(ark_balance "$to")
  # A busy receiver can miss the default 30s RPC deadline; give it a real
  # one and one retry before declaring the receiver unresponsive.
  pk=$(wavecli "$to" ark oor receive --timeout 60s 2>/dev/null \
    | jq -r '.pubkey_xonly_hex // empty')
  [[ -n "$pk" ]] || pk=$(wavecli "$to" ark oor receive --timeout 60s 2>/dev/null \
    | jq -r '.pubkey_xonly_hex // empty')
  if [[ -z "$pk" ]]; then
    status=recv_failed
  else
    # The daemon re-drives a submit whose operator response was lost every
    # 30s (seen live: a postgres serialization conflict burst dropped one
    # response and the retry landed at exactly 120s). The deadline must
    # outlast that loop, so a slow payment records as a slow pass with its
    # true latency, not as a false failure.
    err=$(wavecli "$from" ark send oor --pubkey "$pk" \
      --amount "$amount" --yes --timeout 300s 2>&1)
    sid=$(printf '%s' "$err" | jq -r '.session_id // empty' 2>/dev/null)
    if [[ -z "$sid" ]]; then
      status=fail
    else
      status=timeout
      local deadline=$(( $(date +%s) + 360 ))
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

      # The sender reaching COMPLETED does not mean the recipient got it.
      # An incoming transfer can be dropped while the recipient has its own
      # outgoing session in flight, leaving the value live at the operator
      # and invisible to its owner. Poll the receiver for the credit; if it
      # never lands the payment is undelivered, not a pass.
      if [[ "$status" == pass && -n "$recv_before" ]]; then
        local ddl=$(( $(date +%s) + 45 )) delivered=0
        while (( $(date +%s) < ddl )); do
          recv_after=$(ark_balance "$to")
          if [[ -n "$recv_after" ]] && (( recv_after > recv_before )); then
            delivered=1; break
          fi
          sleep 1
        done
        (( delivered )) || status=undelivered
      fi
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

  # Percentiles cover passed payments only: a timed-out payment's duration
  # is the deadline constant, not a measurement, and it would poison the
  # latency series. Failures stay visible through the failed count and the
  # per-send error records.
  CASE_DETAIL=$(jq -sc '
    {sends: length,
     passed: [.[] | select(.status == "pass")] | length,
     undelivered: [.[] | select(.status == "undelivered")] | length,
     failed: [.[] | select(.status != "pass")] | length,
     p50_s: ([.[] | select(.status == "pass") | .duration_s] | sort
             | .[(length/2|floor)] // null),
     max_s: ([.[] | select(.status == "pass") | .duration_s] | max // null),
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

# Count of the client's confirmed rounds. A refresh only counts as a pass
# when this number rises: "no active round left" alone is not success,
# because a client that joined and then dropped at seal time reaps its
# failed FSM within seconds, leaving nothing behind to see (learned in
# epoch 14, where all ten clients rejected the fee quote and the case
# still reported a clean pass).
client_confirmed_rounds() {
  wavecli "$1" ark rounds list 2>/dev/null | jq -r '
    [.rounds[]? | select(.state == "ROUND_STATE_CONFIRMED")] | length' 2>/dev/null
}

# Failure reason for a refresh that produced no confirmed round, read from
# the daemon log window rather than the FSM list, which the reaper empties.
# A fee-quote rejection ("insufficient_residual") is the client's fee
# protection working, not a malfunction, and must not fail the epoch.
client_refresh_outcome() {
  local n=$1 since=$2 win
  win=$(docker logs --since "$since" "$n" 2>&1 \
    | grep -E "Round failed|quote rejected" | tail -3)
  case "$win" in
    *quote\ rejected*|*insufficient_residual*) echo quote_rejected ;;
    *Round\ failed*)                           echo round_failed ;;
    *)                                         echo no_round ;;
  esac
}

# Outpoints a real wallet would refresh now: near batch expiry, or with an
# OOR lineage deep enough to approach the operator's lineage cap. Newline-
# separated; empty when the client has nothing due.
refresh_eligible_outpoints() {
  local n=$1 height=$2
  wavecli "$n" ark vtxos list --status live 2>/dev/null | jq -r \
    --argjson h "$height" \
    --argjson rem "$REFRESH_MAX_REMAINING_BLOCKS" \
    --argjson depth "$REFRESH_MAX_CHAIN_DEPTH" '
    (if type == "array" then . else (.vtxos // []) end)
    | .[]
    | select(((.batch_expiry // 0) - $h < $rem)
             or ((.chain_depth // 0) >= $depth))
    | .outpoint' 2>/dev/null
}

# Selective refresh (v2.1): each client refreshes only its due vtxos; a
# client with nothing due skips, which is a recorded outcome, not a
# failure. Submissions are instant (queue + auto-join) and land inside the
# operator's registration window, so the submitting clients share a round.
# Rounds need a confirmation to reach a terminal state and nothing mines
# here except the harness, so the wait loop mines. Per-client duration is
# submit-to-terminal-round.
case_refresh() {
  local out="$RUNDIR/refresh-results.ndjson"
  : > "$out"
  declare -A t0 done_at confirmed_before submit_status vtxo_count
  local n now height
  local case_start; case_start=$(date -u +%FT%TZ)
  height=$(btc getblockcount)

  for n in $CLIENTS; do
    confirmed_before[$n]=$(client_confirmed_rounds "$n")
    : "${confirmed_before[$n]:=0}"
    t0[$n]=$(date +%s.%N)
    local eligible args=()
    eligible=$(refresh_eligible_outpoints "$n" "$height")
    if [[ -z "$eligible" ]]; then
      submit_status[$n]=skipped
      vtxo_count[$n]=0
      done_at[$n]=$(date +%s.%N)
      continue
    fi
    local op
    while IFS= read -r op; do args+=(--outpoint "$op"); done <<<"$eligible"
    vtxo_count[$n]=$(( ${#args[@]} / 2 ))
    if wavecli "$n" ark vtxos refresh "${args[@]}" --yes --timeout 120s \
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
    local status=${submit_status[$n]} dur confirmed_now
    if [[ "$status" == pending ]]; then
      if [[ -z "${done_at[$n]:-}" ]]; then
        status=timeout; done_at[$n]=$(date +%s.%N)
      else
        confirmed_now=$(client_confirmed_rounds "$n"); : "${confirmed_now:=0}"
        if (( confirmed_now > ${confirmed_before[$n]} )); then
          status=pass
        else
          status=$(client_refresh_outcome "$n" "$case_start")
        fi
      fi
    fi
    dur=$(awk -v a="${t0[$n]}" -v b="${done_at[$n]}" 'BEGIN{printf "%.3f", b-a}')
    jq -cn --arg node "$n" --arg status "$status" --argjson duration_s "$dur" \
      --argjson vtxos "${vtxo_count[$n]:-0}" \
      '{node: $node, status: $status, duration_s: $duration_s,
        vtxos: $vtxos}' >> "$out"
  done

  # A skip (nothing due) and a quote rejection (fee protection) are both
  # expected outcomes: counted in their own buckets, kept out of the timing
  # percentiles, and neither fails the case.
  CASE_DETAIL=$(jq -sc '
    {clients: length,
     passed: [.[] | select(.status == "pass")] | length,
     skipped: [.[] | select(.status == "skipped")] | length,
     quote_rejected: [.[] | select(.status == "quote_rejected")] | length,
     failed: [.[] | select(.status != "pass" and .status != "skipped"
                       and .status != "quote_rejected")] | length,
     vtxos_refreshed: ([.[] | select(.status == "pass") | .vtxos] | add // 0),
     p50_s: ([.[] | select(.status == "pass") | .duration_s] | sort
             | .[(length/2|floor)] // null),
     max_s: ([.[] | select(.status == "pass") | .duration_s] | max // null)}' \
    "$out")
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
    # The deposit amount is recorded per board rather than assumed from
    # config, so the deposited-capital ledger stays exact even if
    # BOARD_AMOUNT is retuned mid-series.
    boarded=$(jq -cn --argjson acc "$boarded" --arg n "$n" --arg s "$status" \
      --argjson bal "$bal" --argjson amt "$BOARD_AMOUNT" \
      --argjson d "$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f", b-a}')" \
      '$acc + [{node: $n, status: $s, amount_sat: $amt,
                balance_before_sat: $bal, duration_s: $d}]')
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
