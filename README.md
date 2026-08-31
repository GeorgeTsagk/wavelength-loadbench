# wavelength-loadbench

A growth benchmark for the Wavelength / Ark stack: one `lumosd` operator and
ten `waved` clients on a regtest network that is **never reset**, where the
chain only advances when the harness mines. One epoch runs every 3 hours: 30
random client-to-client OOR payments (3 waves of 10, all clients sending
concurrently) and one all-client refresh round. The series measures what the
same work costs as the operator's round history, indexer, mailbox and the
clients' sqlite stores accumulate real volume.

Built from the playbook distilled out of
[tapd-loadbench](https://github.com/GeorgeTsagk/tapd-loadbench).

## Live site

Rendered from `docs/` by GitHub Pages: the series charts on the index page,
and the per-operation bottleneck verdicts plus a client profile explorer on
the snapshot page.

## What is measured

- **Timed cases** (`send`, `refresh`) with a per-operation time budget from
  four independent sources: wall clock, cgroup CPU delta, bracketed
  block/mutex profile deltas, and pg_stat_statements time. The budget yields
  one bottleneck verdict per operation per node (`bench/bottleneck.py`).
- **Growth**: operator postgres size and per-table breakdown, per-client
  sqlite footprint including WAL and its checkpoint backlog, memory high
  water marks, goroutine counts.
- **Passive**: operator round lifecycle and batch sweeper activity from the
  epoch's log window.

## Versions under test

Pinned release tags plus one local commit each that adds an exact-bracket
CPU profile endpoint (`bench/patch-pprof.sh`): lumos v0.1.0 and wavelength
v0.1.1. Repinning is deliberate and noted via `SCHEMA_NOTE` in
`bench/config.env`.

**The operator repo (lightninglabs/lumos) is private.** This repository
carries only the harness, the epoch records and the rendered site. Operator
source never enters it, operator profiles are never symbolised for
publication (`docs/profiles.json` holds only the client, whose repo is
public), the operator's rows in `docs/bottlenecks.json` carry budget and
verdict but no symbols or SQL, and its storage breakdown names only
protocol-generic tables. Raw operator profiles stay in the gitignored
`logs/`.

## Layout

```
bench/          the harness: config.env holds every tunable, commented
.ddp/           generated docker compose for the 15-container network
data/           epochs.jsonl, one append-only JSON record per epoch
docs/           the static site GitHub Pages serves
logs/           per-epoch logs and raw profiles (gitignored, large)
```

## Running

```
bench/gen-compose.sh     # regenerate compose after config changes
bench/build-images.sh    # build daemon images from the pinned local checkouts
bench/deploy.sh          # idempotent bring-up + first-boot bootstrap
bench/epoch.sh           # one epoch, appends one record
bench/render.sh          # records -> docs/
bench/cron.sh            # what the schedule runs: selftest, deploy, epoch, render, commit, push
```

The images build from local checkouts (`LUMOS_SRC`, `WAVELENGTH_SRC` in
config.env) at pinned revisions; `build-images.sh` refuses to build a dirty
or unpinned tree.
