#!/usr/bin/env bash
# Check that the libraries provide everything the scripts call, and that
# every script parses. A truncated library once cost the reference harness
# three hours of silent cron failures; this catches that in a second (P1).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set -a; . "$HERE/config.env"; set +a
. "$HERE/lib/common.sh"; . "$HERE/lib/metrics.sh"; . "$HERE/lib/cases.sh"

REQUIRED=(die log btc lnd lumoscli wavecli mine mine_synced mine_until
          wait_electrs_synced ark_balance live_vtxos health_check
          ensure_operator_funded prom prom_fetch prom_json prom_port
          pprof_port cgroup_memory cgroup_cpu all_container_stats
          postgres_bytes operator_row_counts client_sqlite_bytes
          capital_metrics
          client_wal_state client_metrics operator_metrics snapshot
          capture_profiles capture_all cpu_profile_start cpu_profile_stop
          case_cpu pg_stat_reset pg_stat_top pg_total_exec_ms round_stats
          one_oor_send case_send case_refresh client_round_active
          client_confirmed_rounds client_refresh_outcome
          refresh_eligible_outpoints
          ensure_boarded board_done)
missing=()
for f in "${REQUIRED[@]}"; do
  declare -F "$f" >/dev/null || missing+=("$f")
done
if (( ${#missing[@]} )); then
  echo "MISSING functions: ${missing[*]}" >&2
  exit 1
fi

for v in CLIENTS NUM_CLIENTS CASES SEND_TOTAL SEND_WAVES BOARD_FLOOR \
         OPERATOR_COUNT_TABLES LUMOS_REV WAVELENGTH_REV; do
  [[ -n "${!v:-}" ]] || { echo "MISSING variable: $v" >&2; exit 1; }
done

for s in "$HERE"/*.sh "$HERE"/lib/*.sh; do bash -n "$s" || exit 1; done

# The curated table list must match the live schema, or the row counts and
# the size breakdown quietly become null forever. Only checked while the
# network is up; the static checks above never depend on docker.
if docker inspect -f '{{.State.Running}}' wb-pg 2>/dev/null | grep -q true; then
  for t in $OPERATOR_COUNT_TABLES; do
    docker exec wb-pg psql -U lightning -d lumos -tAc \
      "SELECT 1 FROM information_schema.tables
        WHERE table_schema='public' AND table_name='$t'" 2>/dev/null \
      | grep -q 1 || { echo "MISSING operator table: $t" >&2; exit 1; }
  done
fi

echo "selftest OK: ${#REQUIRED[@]} functions, all scripts parse"
