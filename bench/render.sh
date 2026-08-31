#!/usr/bin/env bash
# Render data/epochs.jsonl into the static site under docs/.
#
# The site is plain HTML plus the raw JSON: no build step, no dependencies,
# so the underlying data stays inspectable rather than only existing as
# pixels. Remember: the page reads a PROJECTION of each record, built here.
# Adding a field to the record does not put it on the page until this
# projection carries it.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
DATA="$ROOT/data/epochs.jsonl"
OUT="$ROOT/docs"

[[ -s "$DATA" ]] || { echo "no data yet at $DATA"; exit 0; }
mkdir -p "$OUT"

jq -s '[ .[] | {
    epoch, finished_at, duration_s,
    versions: {lumosd: .versions.lumosd, waved: .versions.waved},
    cases: [.cases[] | {name, status, duration_s, db_ms, detail}],
    boards: [(.boards // [])[] | {node, status}],
    rounds: (.rounds // {}),
    after: {
      block_height: .after.block_height,
      operator_pg_bytes: .after.operator.pg.total,
      clients_sqlite_bytes:
        ([.after.clients[] | (.sqlite | values | add) // 0] | add),
      client01_sqlite_bytes:
        ((.after.clients["wb-client01"].sqlite | values | add) // null),
      operator_mem: {
        mem_bytes: .after.operator.container.mem_bytes,
        mem_peak_bytes: .after.operator.container.mem_peak_bytes
      },
      client01_mem: {
        mem_bytes: .after.clients["wb-client01"].container.mem_bytes,
        mem_peak_bytes: .after.clients["wb-client01"].container.mem_peak_bytes
      },
      operator_goroutines: .after.operator.goroutines,
      client01_goroutines: .after.clients["wb-client01"].goroutines
    },
    delta: {
      operator_pg_bytes: .delta.operator_pg_bytes,
      clients_sqlite_bytes: .delta.clients_sqlite_bytes
    },
    capital: (if .after.capital == null then null else {
      deployed_sat: .after.capital.ledger.deployed_capital,
      spendable_sat: .after.capital.clients_spendable_sat,
      live_vtxo_sat: .after.capital.vtxo_value.live,
      claims_sat: (.after.capital.ledger.user_vtxo_claims
                   | if . == null then null else -. end),
      wallet_confirmed_sat: .after.capital.wallet_confirmed_sat,
      fees_extracted_sat: .after.capital.fees_extracted_sat
    } end),
    capital_check: (.capital_check // null)
  } ] | sort_by(.epoch)' "$DATA" > "$OUT/epochs.json"

# Profiles into browsable JSON (client only: the operator repo is private),
# and the verdict pass (both nodes, operator rows redacted in the public
# copy). Skipped cleanly without a Go toolchain.
if command -v go >/dev/null 2>&1; then
  python3 "$ROOT/bench/symbolize.py" "$ROOT" "$OUT/profiles.json" \
    || echo "symbolize failed (continuing)"
  python3 "$ROOT/bench/bottleneck.py" "$ROOT" \
    "$ROOT/logs/bottlenecks-full.json" "$OUT/bottlenecks.json" \
    || echo "bottleneck pass failed (continuing)"
else
  echo "skipping profile passes (no go toolchain)"
fi

# The detail page shares the series page styling. Generate the stylesheet
# from index.html rather than keeping a second copy that can drift.
python3 - "$OUT" <<'CSSEOF'
import pathlib, sys
out = pathlib.Path(sys.argv[1])
src = (out / "index.html").read_text()
css = src[src.index("<style>") + len("<style>"):src.index("</style>")].strip()
(out / "tokens.css").write_text(
    "/* Generated from index.html by bench/render.sh. Do not edit. */\n" + css + "\n"
)
CSSEOF

# The snapshot page needs a few whole-record fields of the latest epoch that
# the projection drops. PUBLIC FILE: strip anything operator-internal (the
# pg table names are schema of a private repo).
jq -s 'sort_by(.epoch) | last | {
    epoch, finished_at, versions, rounds,
    boards: [(.boards // [])[] | {node, status, duration_s}],
    cases: [.cases[] | {name, status, duration_s, db_ms, detail}],
    clients: (.after.clients | map_values({
      balance_sat, live_vtxos, goroutines, heap_bytes,
      sqlite_bytes: ((.sqlite | values | add) // null),
      wal: .wal
    })),
    operator: {
      pg_total: .after.operator.pg.total,
      goroutines: .after.operator.goroutines,
      heap_bytes: .after.operator.heap_bytes
    }
  }' "$DATA" > "$OUT/latest.json"

echo "wrote $OUT/epochs.json ($(jq 'length' "$OUT/epochs.json") epochs, $(du -h "$OUT/epochs.json" | cut -f1))"
echo "wrote $OUT/latest.json (epoch $(jq -r .epoch "$OUT/latest.json"))"
