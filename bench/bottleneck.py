#!/usr/bin/env python3
"""Turn one epoch's profiles into a per-operation bottleneck verdict.

The point is to answer "what is holding this operation up" without opening a
profile. The old export could not answer it at all: heap, allocs and goroutine
say where memory came from and what exists, and none of them account for wall
clock. So the first thing here is a time budget per operation, from four
independent sources:

  wall    the operation's own duration
  cpu     the daemon's cgroup CPU delta across exactly that operation
  block   goroutine blocking delay, from the block profile bracket
  mutex   lock contention delay, from the mutex profile bracket
  db      summed statement time from pg_stat_statements over that window

Whichever dominates names the class of bottleneck, and only then is a profile
worth reading, which is why the top rows are carried alongside. The residual
class matters as much as the others: an operation whose wall clock is not
explained by CPU, locks or queries is waiting on the network, the chain or a
poll interval, and no amount of code optimisation moves it.

Filtering differs by dimension on purpose. For heap and allocs, folding onto
repository code is right, since the caller is what allocated. For cpu, block
and mutex it is wrong: the interesting blocker is almost always outside the
org, in modernc.org/sqlite lock acquisition or database/sql connection waits,
and folding those away deletes the answer.

The lumos repo is private, so two outputs are written: the full result
(operator top rows and SQL text included) goes to the local path, and a
redacted copy (operator budgets and verdicts only, client rows intact) goes
to the public path for the site.

Usage: bottleneck.py <repo-root> <local-out.json> <public-out.json>
"""

import json
import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from symbolize import OWNED, clean, pkg_of, pprof  # noqa: E402

TOP_N = 12

# The block profile cannot be used raw. Every long-lived parked goroutine keeps
# accruing delay for as long as it waits, so the total is dominated by idle
# event loops and grows with goroutine count rather than with load. Measured on
# a freshly started node: 217.77s of reported delay after 60s of uptime, of
# which 99.9% was gRPC loopyWriter, the dns resolver watcher and tapd's own rfq
# mainEventLoop sitting in select. Real dependency blocking was 0.22s.
#
# So focus onto the things that can actually stall an operation: the sql pool
# and driver, sqlite's own locks, semaphore and waitgroup waits, and real IO.
# An allowlist is the safe direction here: something genuinely new gets
# under-reported rather than manufacturing a bottleneck that is not there. The
# unfiltered total is kept alongside so nothing is silently hidden.
BLOCK_FOCUS = (
    r"database/sql|modernc\.org/sqlite|jackc/pgx|sync\.runtime_Semacquire"
    r"|sync\.\(\*(Mutex|RWMutex|WaitGroup)\)|internal/poll|os\.\(\*File\)"
)
# Per-transaction and pool-maintenance watchdogs sit inside database/sql but
# are idle waits, not contention.
BLOCK_HIDE = (
    r"database/sql\.\(\*Tx\)\.awaitDone"
    r"|database/sql\.\(\*DB\)\.connectionOpener"
)

# pprof prints values with a unit suffix that depends on the sample type. Cover
# time and count units here; the byte units live in symbolize for the memory
# profiles.
TIME_UNITS = {
    "ns": 1e-9, "us": 1e-6, "µs": 1e-6, "ms": 1e-3,
    "s": 1.0, "mins": 60.0, "hrs": 3600.0,
}
ROW = re.compile(
    r"^\s*(-?[\d.]+)([a-zµ]*)\s+(-?[\d.]+)%\s+(-?[\d.]+)%"
    r"\s+(-?[\d.]+)([a-zµ]*)\s+(-?[\d.]+)%\s+(.*)$"
)


def rows_seconds(text):
    """Parse a -top listing whose values are durations, into seconds."""
    out = []
    for line in text.splitlines():
        m = ROW.match(line)
        if not m:
            continue
        flat, fu, _, _, cum, cu, _, name = m.groups()
        name = clean(name.strip())
        out.append({
            "fn": name,
            "pkg": pkg_of(name),
            "self_s": float(flat) * TIME_UNITS.get(fu, 1.0),
            "cum_s": float(cum) * TIME_UNITS.get(cu, 1.0),
        })
    return out


def top_time(profile, base=None, sample_index=None,
             focus=None, hide=None):
    """Ranked self-time rows for a duration profile, plus its total."""
    args = ["-top", f"-nodecount={TOP_N * 4}"]
    if sample_index:
        args.append(f"-sample_index={sample_index}")
    if base:
        args += ["-base", str(base)]
    if focus:
        args += ["-focus", focus]
    if hide:
        args += ["-hide", hide]
    rows = rows_seconds(pprof(args + [str(profile)]))
    total = sum(r["self_s"] for r in rows)
    return rows[:TOP_N], total


def by_package(rows, key="self_s"):
    agg = {}
    for r in rows:
        agg[r["pkg"]] = agg.get(r["pkg"], 0.0) + r[key]
    ranked = sorted(agg.items(), key=lambda kv: -kv[1])
    return [{"pkg": p, key: v} for p, v in ranked[:TOP_N]]


def classify(wall, cpu, db, block, mutex):
    """Name the dominant class, and say why in the same breath.

    Thresholds are deliberately loose. The budget numbers travel with the
    verdict, so a borderline call is auditable rather than authoritative.

    block and mutex are goroutine-seconds, so they legitimately exceed wall
    clock when work is concurrent. That is why the blocking test needs a full
    multiple of wall and a quiet CPU, rather than any share of it.
    """
    if wall <= 0:
        return "unknown", "no duration recorded"
    frac = lambda v: v / wall  # noqa: E731
    if frac(cpu) >= 0.6:
        return "cpu-bound", f"daemon burned {cpu:.1f}s CPU over {wall:.1f}s wall"
    if frac(db) >= 0.5:
        return "db-bound", f"{db:.1f}s of statement time over {wall:.1f}s wall"
    if frac(mutex) >= 0.3:
        return "lock-bound", f"{mutex:.1f}s of mutex delay over {wall:.1f}s wall"
    if frac(block) >= 1.0 and frac(cpu) < 0.3:
        return "blocking-bound", (
            f"{block:.1f}s goroutine-seconds blocked over {wall:.1f}s wall, "
            f"CPU only {cpu:.1f}s"
        )
    return "latency-bound", (
        f"{wall:.1f}s wall unexplained by CPU ({cpu:.1f}s), queries "
        f"({db:.1f}s) or locks ({mutex:.1f}s): waiting on network, chain or a "
        f"poll interval"
    )


def load_record(rundir):
    path = rundir / "record.json"
    if not path.exists():
        return {}
    return json.loads(path.read_text())


# Operator rows carry private symbols and SQL text; the public copy keeps
# only their budget and verdict. The client is public code, published whole.
PRIVATE_NODES = ("wb-lumosd",)


def redact(result):
    pub = json.loads(json.dumps(result))
    for op in pub["operations"]:
        if op["node"] in PRIVATE_NODES:
            op["top"] = {"redacted":
                         "operator symbols are private; see budget/verdict"}
    return pub


def main():
    root = pathlib.Path(sys.argv[1])
    out_path = pathlib.Path(sys.argv[2])
    public_path = pathlib.Path(sys.argv[3])

    # A directory without record.json is from a run that died before writing
    # its record, so its profiles belong to no measured epoch. Picking it would
    # silently replace a good report with an empty one.
    rundirs = sorted(
        d for d in (root / "logs").glob("epoch-*")
        if (d / "pprof").is_dir() and (d / "record.json").exists()
    )
    if not rundirs:
        print("no epochs with profiles yet")
        return
    rundir = rundirs[-1]
    pprof_dir = rundir / "pprof"
    epoch = int(rundir.name.split("-")[1])
    record = load_record(rundir)

    cases = {c["name"]: c for c in record.get("cases", [])}
    result = {
        "epoch": epoch,
        "lumosd_version": record.get("versions", {}).get("lumosd"),
        "waved_version": record.get("versions", {}).get("waved"),
        "owned_pattern": OWNED,
        # Named blind spot (P15): the clients run in-process sqlite, which has
        # no server-side statement timing, so a client can never be classified
        # db-bound. Its storage time shows up as CPU (driver work) and
        # blocking (pool waits) instead, which the daemon profile does see.
        "db_note": "db_s exists only for the operator (postgres); "
                   "client sqlite time surfaces in cpu_s and block_s",
        "operations": [],
    }

    nodes = sorted({f.name.split(".")[0] for f in pprof_dir.glob("*.pb.gz")})
    for case_name, case in cases.items():
        wall = float(case.get("duration_s") or 0)
        pgstat = []
        pg_path = rundir / f"pgstat-{case_name}.json"
        if pg_path.exists():
            try:
                pgstat = json.loads(pg_path.read_text() or "[]")
            except json.JSONDecodeError:
                pgstat = []

        for node in nodes:
            cpu_prof = pprof_dir / f"{node}.{case_name}.cpu.pb.gz"
            cpu_rows, cpu_prof_s = ([], 0.0)
            if cpu_prof.exists():
                cpu_rows, cpu_prof_s = top_time(cpu_prof)

            def bracket(kind, sample_index, focus=None, hide=None):
                pre = pprof_dir / f"{node}.pre-{case_name}.{kind}.pb.gz"
                post = pprof_dir / f"{node}.post-{case_name}.{kind}.pb.gz"
                if not (pre.exists() and post.exists()):
                    return [], 0.0
                return top_time(post, base=pre,
                                sample_index=sample_index,
                                focus=focus, hide=hide)

            # Focused figure drives the verdict, raw is carried for audit.
            block_rows, block_s = bracket(
                "block", "delay", focus=BLOCK_FOCUS, hide=BLOCK_HIDE)
            _, block_raw_s = bracket("block", "delay")
            # Contention events are real by construction, so no focus here.
            mutex_rows, mutex_s = bracket("mutex", "delay")

            # cgroup CPU is the authoritative figure: the profile samples at
            # 100Hz and misses short bursts, the counter cannot.
            cpu_s = float((case.get("cpu_usec") or {}).get(node, 0)) / 1e6

            # Only the operator talks to postgres; the whole statement
            # window is its. Clients get db_s = 0 with the blind spot named
            # in db_note above.
            node_stmts = pgstat if node == "wb-lumosd" else []
            db_s = sum(q.get("total_ms", 0) for q in node_stmts) / 1000.0

            verdict, why = classify(wall, cpu_s, db_s, block_s, mutex_s)
            result["operations"].append({
                "case": case_name,
                "node": node,
                "status": case.get("status"),
                "budget": {
                    "wall_s": round(wall, 2),
                    "cpu_s": round(cpu_s, 2),
                    "cpu_profile_s": round(cpu_prof_s, 2),
                    "block_s": round(block_s, 2),
                    "block_raw_s": round(block_raw_s, 2),
                    "mutex_s": round(mutex_s, 2),
                    "db_s": round(db_s, 2),
                },
                "verdict": verdict,
                "why": why,
                "top": {
                    "cpu": cpu_rows,
                    "cpu_packages": by_package(cpu_rows),
                    "block": block_rows,
                    "block_packages": by_package(block_rows),
                    "mutex": mutex_rows,
                    "db": node_stmts[:TOP_N],
                },
            })

    out_path.write_text(json.dumps(result, separators=(",", ":")))
    public_path.write_text(json.dumps(redact(result), separators=(",", ":")))
    verdicts = {}
    for op in result["operations"]:
        verdicts[op["verdict"]] = verdicts.get(op["verdict"], 0) + 1
    print(f"wrote {out_path} + redacted {public_path} (epoch {epoch}, "
          f"{len(result['operations'])} operations, {verdicts})")


if __name__ == "__main__":
    main()
