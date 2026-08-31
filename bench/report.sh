#!/usr/bin/env bash
# Compact regression report for the most recent epoch: how it compares to the
# trailing baseline, and anything that looks off. Exists so the per-run
# reporting step reads a few lines of conclusions rather than the history.
#
# Usage: bench/report.sh [baseline_window]   (default 10 epochs)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA="$ROOT/data/epochs.jsonl"
WINDOW="${1:-10}"

[[ -s "$DATA" ]] || { echo "no epochs recorded yet"; exit 0; }

jq -s --argjson w "$WINDOW" -r '
  sort_by(.epoch) as $all |
  ($all | last) as $cur |
  ($all[:-1] | .[-$w:]) as $base |

  # These numbers grow by design: the operator has strictly more state every
  # epoch. Comparing against the window mean would flag every epoch forever,
  # so the prediction is the last reading plus the average per-epoch step,
  # and the flag is departure from that trend.
  def series($name): [$base[] | .cases[] | select(.name == $name)
                      | select(.status == "pass") | .duration_s];
  def trend($s): if ($s | length) < 2 then null
                 else (($s | last) - ($s | first)) / (($s | length) - 1) end;
  def predict($s): if ($s | length) < 2 then null
                   else ($s | last) + trend($s) end;
  def mb($b): if $b == null then "n/a"
              else (($b / 1048576) * 100 | round / 100 | tostring) + " MB" end;

  "epoch \($cur.epoch)  lumosd \($cur.versions.lumosd)  waved \($cur.versions.waved)  height \($cur.after.block_height)",
  "baseline: \($base | length) prior epochs",
  "",
  "cases (flagged against the trend, not the mean, because these grow by design):",
  ( $cur.cases[] as $c
    | series($c.name) as $s
    | predict($s) as $p
    | ( if $c.status != "pass" then "!! \($c.name): \($c.status)"
        elif $p != null and $c.duration_s > ($p * 1.35 + 5)
        then "!! \($c.name): \($c.duration_s)s against a trend of \($p * 100 | round / 100)s"
        else "   \($c.name): \($c.duration_s)s (trend \(if $p == null then "n/a" else ($p * 100 | round / 100 | tostring) end)s)"
        end ) ),
  "",
  "send detail: \($cur.cases[] | select(.name == "send") | .detail | "\(.passed)/\(.sends) passed, p50 \(.p50_s)s, max \(.max_s)s")",
  "refresh detail: \($cur.cases[] | select(.name == "refresh") | .detail | "\(.passed)/\(.clients) clients, p50 \(.p50_s)s, max \(.max_s)s\(if (.quote_rejected // 0) > 0 then ", \(.quote_rejected) fee-quote rejections" else "" end)")",
  "growth: operator \(mb($cur.delta.operator_pg_bytes)), clients \(mb($cur.delta.clients_sqlite_bytes))",
  "rounds: \($cur.rounds.rounds_confirmed) confirmed, \($cur.rounds.rounds_failed) failed, \($cur.rounds.batch_sweeps) sweeps",
  ( ($cur.capital_check // {}) as $chk
    | ($cur.after.capital // {}) as $cap
    | if $chk.residual_sat == null then "   capital: not measured this epoch"
      elif $chk.residual_sat != 0
      then "!! CAPITAL NOT CONSERVED: residual \($chk.residual_sat) sat (deposited \($chk.deposited_cum_sat), spendable \($cap.clients_spendable_sat), fees \($cap.fees_extracted_sat))"
      else "   capital conserved: \($chk.deposited_cum_sat) sat deposited, all accounted (lock ratio \((($cap.ledger.deployed_capital // 0) * 100 / ($cap.clients_spendable_sat // 1) | round) / 100)x)"
      end ),
  ( [$cur.after.clients[] | select(.balance_sat != null and (.balance_sat | tonumber) < 20000)] as $low
    | if ($low | length) > 0
      then "!! clients running low on balance: \($low | length) below 20k sat"
      else "   client balances healthy" end ),
  ( [$cur.after.clients[] | .wal.unbackfilled // 0] | max as $u
    | if $u > 10000
      then "!! largest client WAL backlog: \($u) unbackfilled frames"
      else "   wal checkpointing healthy (max backlog \($u) frames)" end ),
  ( [$cur.after.containers | to_entries[] | select(.value.restart_count > 0)] as $r
    | if ($r | length) > 0
      then "!! containers with restarts: \([$r[] | "\(.key)=\(.value.restart_count)"] | join(", "))"
      else "   no container restarts" end )
' "$DATA"
