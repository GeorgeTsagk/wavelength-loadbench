# shellcheck shell=bash
# Metric collection. Sourced by epoch.sh. Every function prints JSON on
# stdout. A failed measurement prints null (or nothing, which callers turn
# into null), never 0: a zero reads as an empty database, not missing data,
# and it corrupted the reference series twice (P5).

ALL_CONTAINERS="wb-bitcoind wb-electrs wb-lnd wb-pg wb-lumosd $CLIENTS"

# Host-side ports, kept in lockstep with gen-compose.sh.
prom_port() {
  case "$1" in
    wb-lumosd) echo 19090 ;;
    wb-client*) echo "190${1#wb-client}" ;;
  esac
}
pprof_port() {
  case "$1" in
    wb-lumosd) echo 16060 ;;
    wb-client*) echo "161${1#wb-client}" ;;
  esac
}

# Nodes whose profiles the harness collects. Every daemon runs with block and
# mutex sampling enabled (same binary, same rates), but only these two are
# fetched: the operator, and one designated client. Clients are symmetric, so
# one observed client stands for all ten without 10x the profile volume.
PPROF_NODES="wb-lumosd wb-client01"
PROFILE_KINDS="heap goroutine allocs block mutex"

# --- cgroup readings (copied from the reference harness) ---

cgroup_memory() {
  local node=$1 cid base anon file inact kstack slab current peak
  cid=$(docker inspect -f '{{.Id}}' "$node" 2>/dev/null) || { echo '{}'; return; }
  for base in "/sys/fs/cgroup/system.slice/docker-$cid.scope" \
              "/sys/fs/cgroup/docker/$cid"; do
    [[ -r "$base/memory.current" ]] || continue
    anon=$(awk '/^anon /{print $2}' "$base/memory.stat")
    file=$(awk '/^file /{print $2}' "$base/memory.stat")
    inact=$(awk '/^inactive_file /{print $2}' "$base/memory.stat")
    current=$(cat "$base/memory.current")
    peak=$(cat "$base/memory.peak" 2>/dev/null || echo 0)
    jq -cn --argjson a "${anon:-0}" --argjson f "${file:-0}" \
      --argjson c "${current:-0}" --argjson i "${inact:-0}" \
      --argjson p "${peak:-0}" \
      '{anon_bytes: $a, file_bytes: $f, current_bytes: $c,
        mem_peak_bytes: $p,
        mem_bytes: (if $c > $i then $c - $i else $c end)}'
    return
  done
  echo '{}'
}

cgroup_cpu() {
  local node=$1 cid base u us sy
  cid=$(docker inspect -f '{{.Id}}' "$node" 2>/dev/null) || { echo '{}'; return; }
  for base in "/sys/fs/cgroup/system.slice/docker-$cid.scope" \
              "/sys/fs/cgroup/docker/$cid"; do
    [[ -r "$base/cpu.stat" ]] || continue
    u=$(awk '/^usage_usec /{print $2}' "$base/cpu.stat")
    us=$(awk '/^user_usec /{print $2}' "$base/cpu.stat")
    sy=$(awk '/^system_usec /{print $2}' "$base/cpu.stat")
    jq -cn --argjson u "${u:-0}" --argjson us "${us:-0}" --argjson sy "${sy:-0}" \
      '{cpu_usec: $u, cpu_user_usec: $us, cpu_system_usec: $sy}'
    return
  done
  echo '{}'
}

all_container_stats() {
  local out="{}" n
  for n in $ALL_CONTAINERS; do
    out=$(jq -cn --argjson acc "$out" --arg k "$n" \
      --argjson v "$(jq -cn --argjson m "$(cgroup_memory "$n")" \
        --argjson c "$(cgroup_cpu "$n")" \
        --argjson r "$(docker inspect -f '{{.RestartCount}}' "$n" 2>/dev/null || echo 0)" \
        '$m + $c + {restart_count: $r}')" '$acc + {($k): $v}')
  done
  printf '%s' "$out"
}

# --- prometheus (one scrape per node per snapshot, cached) ---

declare -A PROM_CACHE=()

prom_fetch() {
  local node=$1 body="" try port
  port=$(prom_port "$node")
  [[ -n "$port" ]] || return 0
  for try in 1 2 3; do
    body=$(curl -s --max-time 30 "localhost:$port/metrics" 2>/dev/null)
    [[ -n "$body" ]] && break
    sleep 2
  done
  PROM_CACHE[$node]="$body"
  [[ -n "$body" ]] || log "  WARNING: prometheus scrape of $node returned nothing"
}

prom() {
  local node=$1 metric=$2
  [[ -n "${PROM_CACHE[$node]:-}" ]] || prom_fetch "$node"
  printf '%s' "${PROM_CACHE[$node]}" | awk -v m="$metric" '
    $1 == m || index($1, m "{") == 1 { s += $NF; f = 1 }
    END { if (f) print s }'
}

prom_json() {
  local v
  v=$(prom "$1" "$2")
  [[ -n "$v" ]] && printf '%s' "$v" || printf 'null'
}

# --- storage ---

# Total size postgres reports for the operator database, plus per-table
# sizes: table sizes are what say which subsystem is growing. The record is
# public and the operator repo is not, so only the curated tables in
# OPERATOR_COUNT_TABLES appear by name (protocol-generic concepts that the
# public client repo also uses); everything else is folded into "_other".
postgres_bytes() {
  local total tables allow
  total=$(docker exec wb-pg psql -U lightning -d lumos -tAc \
    "SELECT pg_database_size('lumos')" 2>/dev/null || echo null)
  allow=$(printf '%s\n' $OPERATOR_COUNT_TABLES | jq -Rn '[inputs]')
  tables=$(docker exec wb-pg psql -U lightning -d lumos -tAF$'\t' -c \
    "SELECT relname, pg_total_relation_size(c.oid)
       FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public' AND c.relkind = 'r'
      ORDER BY 2 DESC" 2>/dev/null \
    | jq -Rn --argjson allow "$allow" '
        [inputs | select(length>0) | split("\t")
         | {key: .[0], value: (.[1]|tonumber)}]
        | (map(select(.key as $k | $allow | index($k))) | from_entries? // {})
          as $named
        | ($named | to_entries | map(.value) | add // 0) as $namedsum
        | (map(.value) | add // 0) as $sum
        | $named + {_other: ($sum - $namedsum)}' 2>/dev/null || echo '{}')
  jq -cn --argjson total "${total:-null}" --argjson tables "${tables:-\{\}}" \
    '{total: $total, top_tables: $tables}'
}

# Exact row counts for the operator tables that grow with workload. Exact
# count(*), not pg_stat estimates, which lag behind reality (P4). The list is
# reconciled against the live schema by selftest.sh: a renamed table must
# fail loudly there, not silently record null forever.
OPERATOR_COUNT_TABLES="${OPERATOR_COUNT_TABLES:-}"

operator_row_counts() {
  local out="{}" t v
  for t in $OPERATOR_COUNT_TABLES; do
    v=$(docker exec wb-pg psql -U lightning -d lumos -tAc \
      "SELECT count(*) FROM \"$t\"" 2>/dev/null | tr -d '[:space:]')
    [[ "$v" =~ ^[0-9]+$ ]] || v=null
    out=$(jq -cn --argjson acc "$out" --arg k "$t" --argjson v "$v" \
      '$acc + {($k): $v}')
  done
  printf '%s' "$out"
}

# Every sqlite database file a client holds (main + wal + shm), found by
# glob rather than a hardcoded name so a layout change surfaces as a new
# entry instead of a silent zero.
client_sqlite_bytes() {
  local node=$1
  docker exec "$node" sh -c '
    find /root/.waved -name "*.db" -o -name "*.db-wal" -o -name "*.db-shm" 2>/dev/null \
      | while read -r f; do printf "%s\t%s\n" "$f" "$(stat -c %s "$f")"; done
  ' 2>/dev/null | jq -Rn '
    [inputs | select(length>0) | split("\t") | {(.[0]): (.[1]|tonumber)}]
    | add // {}'
}

# sqlite WAL checkpoint state from the wal-index header (mxFrame word 4,
# nBackfill word 24 of the shm file). A stalled checkpoint leaves the main
# file untouched while the WAL grows without bound; the reference instance
# hit 4.2 GB before anyone noticed (P13).
client_wal_state() {
  local node=$1 db
  db=$(docker exec "$node" sh -c \
    'find /root/.waved -name "*.db" 2>/dev/null | head -1' 2>/dev/null)
  [[ -n "$db" ]] || { printf 'null'; return; }
  local words
  words=$(docker exec "$node" sh -c \
    "[ -f $db-shm ] || exit 1; dd if=$db-shm bs=132 count=1 2>/dev/null | od -An -tu4 -v" \
    2>/dev/null | tr -s ' \n' ' ') || { printf 'null'; return; }
  awk -v words="$words" 'BEGIN {
    n = split(words, w, " ")
    mx = w[5] + 0; nb = w[25] + 0
    printf "{\"mx_frame\":%d,\"n_backfill\":%d,\"unbackfilled\":%d}", mx, nb, mx - nb
  }'
}

# --- per-node blocks ---

client_metrics() {
  local n=$1
  local balj bal pin pout vtxos
  balj=$(wavecli "$n" balance 2>/dev/null || echo '{}')
  bal=$(jq -r '.confirmed_sat // empty' <<<"$balj"); [[ -n "$bal" ]] || bal=null
  pin=$(jq -r '.pending_in_sat // empty' <<<"$balj"); [[ -n "$pin" ]] || pin=null
  pout=$(jq -r '.pending_out_sat // empty' <<<"$balj"); [[ -n "$pout" ]] || pout=null
  vtxos=$(live_vtxos "$n"); [[ -n "$vtxos" ]] || vtxos=null
  prom_fetch "$n"
  jq -cn \
    --argjson balance_sat "$bal" \
    --argjson pending_in_sat "$pin" \
    --argjson pending_out_sat "$pout" \
    --argjson live_vtxos "$vtxos" \
    --argjson sqlite "$(client_sqlite_bytes "$n")" \
    --argjson wal "$(client_wal_state "$n")" \
    --argjson heap_bytes "$(prom_json "$n" go_memstats_heap_inuse_bytes)" \
    --argjson goroutines "$(prom_json "$n" go_goroutines)" \
    --argjson container "$(printf '%s' "${CONTAINER_STATS:-{\}}" | jq -c --arg k "$n" '.[$k] // {}')" \
    '{balance_sat: $balance_sat, pending_in_sat: $pending_in_sat,
      pending_out_sat: $pending_out_sat, live_vtxos: $live_vtxos,
      sqlite: $sqlite, wal: $wal, heap_bytes: $heap_bytes,
      goroutines: $goroutines, container: $container}'
}

# Capital view, from the operator's own double-entry ledger (exposed as
# prometheus gauges), the indexer's per-status vtxo totals, and the operator
# wallet. Client-side sums are passed in by snapshot() so the three
# independent views of user capital (clients' balances, the indexer's live
# value, the ledger's user_vtxo_claims liability) travel together and can be
# cross-checked. Pending in and out are carried separately: a sat leaving a
# sender's confirmed balance shows up once, as that sender's pending_out (a
# queued refresh does the same with its locked vtxos), so conservation must
# count each pending bucket once and never net them against each other.
# Ledger revenue accounts are negative by accounting convention;
# fees_extracted_sat flips them positive.
capital_metrics() {
  local spendable=$1 pending_in=$2 pending_out=$3
  prom_fetch wb-lumosd
  local ledger
  ledger=$(printf '%s' "${PROM_CACHE[wb-lumosd]}" | awk '
    /^lumosd_ledger_account_balance_satoshis\{/ {
      a = $0; sub(/.*account="/, "", a); sub(/".*/, "", a)
      printf "%s%s\"%s\":%d", (c++ ? "," : "{"), "", a, $NF
    }
    END { print (c ? "}" : "{}") }')
  local vtxo_val vtxo_cnt
  vtxo_val=$(printf '%s' "${PROM_CACHE[wb-lumosd]}" | awk '
    /^lumosd_vtxos_value_satoshis\{/ {
      s = $0; sub(/.*status="/, "", s); sub(/".*/, "", s)
      printf "%s%s\"%s\":%d", (c++ ? "," : "{"), "", s, $NF
    }
    END { print (c ? "}" : "{}") }')
  vtxo_cnt=$(printf '%s' "${PROM_CACHE[wb-lumosd]}" | awk '
    /^lumosd_vtxos\{/ {
      s = $0; sub(/.*status="/, "", s); sub(/".*/, "", s)
      printf "%s%s\"%s\":%d", (c++ ? "," : "{"), "", s, $NF
    }
    END { print (c ? "}" : "{}") }')
  jq -cn \
    --argjson ledger "${ledger:-{\}}" \
    --argjson vtxo_value "${vtxo_val:-{\}}" \
    --argjson vtxo_count "${vtxo_cnt:-{\}}" \
    --argjson wallet_confirmed "$(prom_json wb-lumosd lumosd_wallet_confirmed_satoshis)" \
    --argjson wallet_unconfirmed "$(prom_json wb-lumosd lumosd_wallet_unconfirmed_satoshis)" \
    --argjson spendable "${spendable:-null}" \
    --argjson pending_in "${pending_in:-null}" \
    --argjson pending_out "${pending_out:-null}" \
    '{ledger: $ledger, vtxo_value: $vtxo_value, vtxo_count: $vtxo_count,
      wallet_confirmed_sat: $wallet_confirmed,
      wallet_unconfirmed_sat: $wallet_unconfirmed,
      clients_spendable_sat: $spendable,
      clients_pending_in_sat: $pending_in,
      clients_pending_out_sat: $pending_out,
      fees_extracted_sat:
        (if $ledger == {} then null else
          (0 - (($ledger.boarding_fee_revenue // 0)
              + ($ledger.refresh_fee_revenue // 0)
              + ($ledger.oor_fee_revenue // 0)
              + ($ledger.offboard_fee_revenue // 0))) end)}'
}

operator_metrics() {
  prom_fetch wb-lumosd
  jq -cn \
    --argjson pg "$(postgres_bytes)" \
    --argjson rows "$(operator_row_counts)" \
    --argjson heap_bytes "$(prom_json wb-lumosd go_memstats_heap_inuse_bytes)" \
    --argjson goroutines "$(prom_json wb-lumosd go_goroutines)" \
    --argjson container "$(printf '%s' "${CONTAINER_STATS:-{\}}" | jq -c '."wb-lumosd" // {}')" \
    '{pg: $pg, rows: $rows, heap_bytes: $heap_bytes,
      goroutines: $goroutines, container: $container}'
}

# Snapshot of the whole network. Sits OUTSIDE any timed window: measurement
# cost must not land in the numbers.
snapshot() {
  CONTAINER_STATS=$(all_container_stats)
  PROM_CACHE=()
  local clients="{}" n
  for n in $CLIENTS; do
    clients=$(jq -cn --argjson acc "$clients" --arg k "$n" \
      --argjson v "$(client_metrics "$n")" '$acc + {($k): $v}')
  done
  # Client-side capital sums. Null (not zero) when any client failed to
  # report, so a partial read can never fake a conservation violation (P5).
  local spendable pending_in pending_out
  spendable=$(jq -r 'if any(.[]; .balance_sat == null) then "null"
    else ([.[].balance_sat | tonumber] | add) end' <<<"$clients")
  pending_in=$(jq -r 'if any(.[]; .pending_in_sat == null) then "null"
    else ([.[].pending_in_sat | tonumber] | add) end' <<<"$clients")
  pending_out=$(jq -r 'if any(.[]; .pending_out_sat == null) then "null"
    else ([.[].pending_out_sat | tonumber] | add) end' <<<"$clients")
  local height electrs_tip
  height=$(btc getblockcount 2>/dev/null || echo null)
  electrs_tip=$(curl -s --max-time 5 localhost:13002/blocks/tip/height 2>/dev/null \
    | grep -E '^[0-9]+$' || echo null)
  jq -cn --argjson height "${height:-null}" \
    --argjson electrs_tip "${electrs_tip:-null}" \
    --argjson operator "$(operator_metrics)" \
    --argjson capital "$(capital_metrics "$spendable" "$pending_in" "$pending_out")" \
    --argjson clients "$clients" \
    --argjson containers "$CONTAINER_STATS" \
    '{block_height: $height, electrs_tip: $electrs_tip,
      operator: $operator, capital: $capital, clients: $clients,
      containers: $containers}'
}

# --- profiles ---

# heap and goroutine are levels, read as-is. allocs, block and mutex are
# cumulative since process start, so a pre/post pair diffed with pprof -base
# brackets exactly one case.
capture_profiles() {
  local node=$1 dir=$2 label=$3 port p
  port=$(pprof_port "$node")
  mkdir -p "$dir"
  for p in $PROFILE_KINDS; do
    curl -s --max-time 60 -o "$dir/$node.$label.$p.pb.gz" \
      "localhost:$port/debug/pprof/$p" 2>/dev/null || true
  done
}

capture_all() {
  local dir=$1 label=$2 n
  for n in $PPROF_NODES; do capture_profiles "$n" "$dir" "$label"; done
}

# Exact CPU profile bracket, via the handlers bench/patch-pprof.sh adds.
# seconds= is only a watchdog for a harness that dies mid-case.
cpu_profile_start() {
  local watchdog=$1 n
  for n in $PPROF_NODES; do
    curl -s --max-time 10 -o /dev/null \
      "localhost:$(pprof_port "$n")/debug/cpu/start?seconds=$watchdog" || true
  done
}

cpu_profile_stop() {
  local dir=$1 label=$2 n
  mkdir -p "$dir"
  for n in $PPROF_NODES; do
    curl -s --max-time 60 -o "$dir/$n.$label.cpu.pb.gz" \
      "localhost:$(pprof_port "$n")/debug/cpu/stop" || true
  done
}

# Cumulative CPU microseconds for the daemons a case can load, read at case
# boundaries. The per-case difference is the denominator every CPU profile
# is attributed against.
case_cpu() {
  local out="{}" n v
  for n in wb-lumosd wb-client01 wb-pg wb-electrs; do
    v=$(cgroup_cpu "$n" | jq -r '.cpu_usec // 0')
    out=$(jq -cn --argjson acc "$out" --arg k "$n" --argjson v "${v:-0}" \
      '$acc + {($k): $v}')
  done
  printf '%s' "$out"
}

# --- postgres statement attribution ---

pg_stat_reset() {
  docker exec wb-pg psql -U lightning -d lumos -q -c \
    "SELECT pg_stat_statements_reset();" >/dev/null 2>&1 || true
}

# The statements that dominated the window just closed, by total time, plus
# the total db execution time for the budget (db/wall share).
pg_stat_top() {
  local limit=${1:-15}
  docker exec wb-pg psql -U lightning -d lumos -t -A -F$'\t' -c \
    "SELECT s.calls, round(s.total_exec_time::numeric, 1),
            round(s.mean_exec_time::numeric, 3), s.rows,
            left(regexp_replace(s.query, '\s+', ' ', 'g'), 160)
     FROM pg_stat_statements s JOIN pg_database d ON d.oid = s.dbid
     WHERE d.datname = 'lumos'
     ORDER BY s.total_exec_time DESC LIMIT $limit;" 2>/dev/null \
  | jq -Rsc 'split("\n") | map(select(length > 0) | split("\t")) |
      map({calls: (.[0]|tonumber), total_ms: (.[1]|tonumber),
           mean_ms: (.[2]|tonumber), rows: (.[3]|tonumber), query: .[4]})' \
  || printf '[]'
}

pg_total_exec_ms() {
  local v
  v=$(docker exec wb-pg psql -U lightning -d lumos -tAc \
    "SELECT COALESCE(round(sum(s.total_exec_time)::numeric,1), 0)
       FROM pg_stat_statements s JOIN pg_database d ON d.oid = s.dbid
      WHERE d.datname = 'lumos'" 2>/dev/null | tr -d '[:space:]')
  [[ -n "$v" ]] && printf '%s' "$v" || printf 'null'
}

# --- passive: operator round activity from logs ---
#
# Rounds are driven by the refresh case but their lifecycle runs inside the
# operator; the log window for this epoch is the only place their timing and
# outcome are visible. Grep patterns are validated against live logs by
# selftest once the network has run its first round.
round_stats() {
  local since=$1
  # Patterns verified against lumosd v0.1.0 live logs and source:
  #   rounds/actor: "Round confirmed and complete", "Round failed"
  #   batchsweeper/actor: "Batch expired", "Sweep transaction confirmed"
  docker logs --since "$since" wb-lumosd 2>&1 | awk '
    /Round confirmed and complete/ { confirmed++ }
    /Round failed/                 { failed++ }
    /Batch expired/                { expired++ }
    /Sweep transaction confirmed/  { sweeps++ }
    END {
      printf "{\"rounds_confirmed\":%d,\"rounds_failed\":%d,", confirmed, failed
      printf "\"batches_expired\":%d,\"batch_sweeps\":%d}", expired, sweeps
    }'
}
