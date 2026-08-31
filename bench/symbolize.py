#!/usr/bin/env python3
"""Turn captured pprof profiles into JSON the site can browse.

Two things this does that a plain `pprof -top` dump does not.

Per operation. Each case is bracketed by a capture, and alloc_space is cumulative,
so the difference across a bracket is exactly what that case allocated, and the
heap difference is what it retained. A single end-of-epoch snapshot attributes to
nothing, because it is taken after the last case has finished.

Folded attribution. A dependency frame with a large flat cost is almost always
your code calling it a lot: 16 MiB sitting in btcd/wire.scriptFreeList.Borrow is
really proof.TxDecoder and lndclient.unmarshallTransaction deserializing
transactions. Dropping such frames throws the signal away, so `pprof -show` folds
them into the nearest owned caller instead. Whatever has no owned caller at all
(runtime.allocm, grpc handler chains) is reported as an explicit unattributed
figure rather than quietly disappearing.
"""
import json, re, subprocess, sys, pathlib

TOP_N = 45
OWNED = "lightninglabs|lightningnetwork"
ROW = re.compile(r"^\s*(-?[\d.]+)(\w*)\s+(-?[\d.]+)%\s+(-?[\d.]+)%\s+(-?[\d.]+)(\w*)\s+(-?[\d.]+)%\s+(.*)$")
TOTAL = re.compile(r"of (-?\d+)B total")
UNITS = {"": 1, "B": 1, "b": 1, "kB": 1000, "KB": 1024, "MB": 1024**2, "GB": 1024**3}


def pprof(args):
    r = subprocess.run(["go", "tool", "pprof"] + args, capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else ""


# Go profiles carry their own symbols, so no binary argument is needed; the
# reference harness passed one only out of habit.


def clean(fn):
    """Collapse generic instantiations.

    A generic symbol carries its whole shape inline, and the shape itself contains
    brackets, so a non-greedy regex stops at the wrong one. Match them properly.
    """
    while (i := fn.find("[go.shape")) != -1:
        depth, j = 0, i
        while j < len(fn):
            if fn[j] == "[":
                depth += 1
            elif fn[j] == "]":
                depth -= 1
                if depth == 0:
                    break
            j += 1
        fn = fn[:i] + "[T]" + fn[j + 1:]
    return fn


def pkg_of(fn):
    """Import path of a symbol, which is how a profile maps onto subsystems.

    tapd sets no pprof labels, so there is no named subsystem dimension. The
    package path is the closest thing and it matches the code layout.
    """
    fn = clean(fn).split(" ")[0]
    if "/" in fn:
        head, tail = fn.rsplit("/", 1)
        pkg = head + "/" + tail.split(".")[0]
    else:
        pkg = fn.split(".")[0]
    for prefix, short in (("github.com/lightninglabs/lumos", "lumosd"),
                          ("github.com/lightninglabs/wavelength", "waved"),
                          ("github.com/lightninglabs", "lightninglabs"),
                          ("github.com/lightningnetwork/lnd", "lnd"),
                          ("github.com/btcsuite/btcd", "btcd"),
                          ("google.golang.org/grpc", "grpc"),
                          ("github.com/", ""), ("google.golang.org/", ""),
                          ("modernc.org/", "")):
        if pkg.startswith(prefix):
            rest = pkg[len(prefix):].lstrip("/")
            return f"{short}/{rest}" if short and rest else (short or rest or pkg)
    return pkg


def parse_top(text, scaled):
    rows, total = [], None
    for line in text.splitlines():
        if total is None and (m := TOTAL.search(line)):
            total = int(m.group(1))
        m = ROW.match(line)
        if not m:
            continue
        flat, fu, _, _, cum, cu, cumpct, name = m.groups()
        sf = UNITS.get(fu, 1) if scaled else 1
        sc = UNITS.get(cu, 1) if scaled else 1
        name = clean(name.strip())
        rows.append({"fn": name, "pkg": pkg_of(name),
                     "flat": int(float(flat) * sf), "cum": int(float(cum) * sc),
                     "cum_pct": float(cumpct)})
    return rows, total


def parse_traces(text):
    """Group goroutines by the frame that identifies them.

    Every parked goroutine sits in runtime.gopark, so the top frame says nothing.
    Walk down for the deepest owned frame, falling back to the deepest non-runtime
    frame when none of the stack is ours.
    """
    groups, count, frames = [], None, []

    def flush():
        if count is None or not frames:
            return
        own = [f for f in frames if re.search(OWNED, f)]
        pick = own[-1] if own else next(
            (f for f in reversed(frames)
             if not f.startswith(("runtime.", "internal/"))), frames[-1])
        groups.append({"fn": clean(pick), "pkg": pkg_of(pick), "flat": count,
                       "cum": count, "cum_pct": 0.0,
                       "stack": [clean(f) for f in frames[-5:]]})

    for line in text.splitlines():
        if line.startswith("---"):
            flush(); count, frames = None, []
            continue
        m = re.match(r"^\s+(\d+)\s+(\S.*)$", line)
        if m:
            flush(); count, frames = int(m.group(1)), [m.group(2).strip()]
        elif line.strip() and count is not None:
            frames.append(line.strip())
    flush()

    merged = {}
    for g in groups:
        if g["fn"] in merged:
            merged[g["fn"]]["flat"] += g["flat"]
            merged[g["fn"]]["cum"] += g["flat"]
        else:
            merged[g["fn"]] = g
    out = sorted(merged.values(), key=lambda g: -g["flat"])
    tot = sum(g["flat"] for g in out) or 1
    for g in out:
        g["cum_pct"] = round(g["flat"] / tot * 100, 2)
    return out


def by_package(rows):
    agg = {}
    for r in rows:
        a = agg.setdefault(r["pkg"], {"pkg": r["pkg"], "flat": 0, "cum": 0, "fns": 0})
        a["flat"] += r["flat"]
        a["cum"] = max(a["cum"], r["cum"])
        a["fns"] += 1
    out = sorted(agg.values(), key=lambda a: -abs(a["flat"]))
    tot = sum(abs(a["flat"]) for a in out) or 1
    for a in out:
        a["pct"] = round(a["flat"] / tot * 100, 2)
    return out


def view(profile, base=None, traces=False):
    """One profile rendered both ways: folded onto owned code, and raw by leaf."""
    args = [f"-nodecount={TOP_N}", "-unit=b"]
    if base:
        args += ["-base", str(base)]

    if traces:
        rows = parse_traces(pprof(["-traces"] + ([] if not base else ["-base", str(base)])
                                  + [str(profile)]))
        return {"unit": "count", "total": sum(r["flat"] for r in rows),
                "unattributed": 0, "folded": rows[:TOP_N],
                "raw": rows[:TOP_N], "packages": by_package(rows)}

    raw, total = parse_top(pprof(["-top"] + args + [str(profile)]), True)
    folded, _ = parse_top(
        pprof(["-top"] + args + ["-show", OWNED, str(profile)]), True)
    owned_sum = sum(r["flat"] for r in folded)
    return {"unit": "bytes", "total": total if total is not None else owned_sum,
            "unattributed": (total - owned_sum) if total is not None else 0,
            "folded": folded[:TOP_N], "raw": raw[:TOP_N],
            "packages": by_package(folded)}


# The lumos repo is PRIVATE. Symbolised operator profiles would publish its
# internal function and package names, so only the client (public wavelength
# repo) is symbolised for the site. Operator profiles stay raw and local
# under logs/, and the budget/verdict numbers in bottlenecks.json are the
# operator's public face.
PUBLISHED_NODES = ("wb-client01",)


def main():
    root = pathlib.Path(sys.argv[1])
    out_path = pathlib.Path(sys.argv[2])

    dirs = sorted(d for d in (root / "logs").glob("epoch-*/pprof") if any(d.iterdir()))
    if not dirs:
        print("no profiles captured yet")
        return
    latest, oldest = dirs[-1], dirs[0]
    epoch = int(latest.parent.name.split("-")[1])

    result = {"epoch": epoch, "baseline_epoch": int(oldest.parent.name.split("-")[1]),
              "profiles_available": len(dirs), "owned_pattern": OWNED, "nodes": {}}

    nodes = sorted({f.name.split(".")[0] for f in latest.glob("*.pb.gz")}
                   & set(PUBLISHED_NODES))
    for node in nodes:
        out = {"snapshot": {}, "cases": {}, "growth": {}}

        # End-of-epoch snapshot, or the legacy unlabelled capture.
        for prof in ("heap", "allocs", "goroutine"):
            src = latest / f"{node}.epoch.{prof}.pb.gz"
            if not src.exists():
                src = latest / f"{node}.{prof}.pb.gz"
            if src.exists():
                out["snapshot"][prof] = view(src, traces=(prof == "goroutine"))

        # Per case, from the bracket around it.
        cases = sorted({f.name.split(".")[1][4:] for f in latest.glob(f"{node}.pre-*.pb.gz")})
        for case in cases:
            entry = {}
            for prof in ("heap", "allocs"):
                pre = latest / f"{node}.pre-{case}.{prof}.pb.gz"
                post = latest / f"{node}.post-{case}.{prof}.pb.gz"
                if pre.exists() and post.exists():
                    entry[prof] = view(post, base=pre)
            pre_g = latest / f"{node}.pre-{case}.goroutine.pb.gz"
            post_g = latest / f"{node}.post-{case}.goroutine.pb.gz"
            if pre_g.exists() and post_g.exists():
                a = view(pre_g, traces=True)["total"]
                b = view(post_g, traces=True)["total"]
                entry["goroutine_delta"] = b - a
            if entry:
                out["cases"][case] = entry

        # Across epochs, at the boundary captures.
        if latest != oldest:
            for prof in ("heap", "allocs"):
                old = oldest / f"{node}.epoch.{prof}.pb.gz"
                if not old.exists():
                    old = oldest / f"{node}.{prof}.pb.gz"
                new = latest / f"{node}.epoch.{prof}.pb.gz"
                if not new.exists():
                    new = latest / f"{node}.{prof}.pb.gz"
                if old.exists() and new.exists():
                    out["growth"][prof] = view(new, base=old)

        result["nodes"][node] = out

    # Stacks are only worth carrying for groups anyone will open.
    for node in result["nodes"].values():
        g = node["snapshot"].get("goroutine")
        if g:
            for i, row in enumerate(g["folded"]):
                if i >= 20:
                    row.pop("stack", None)
            g["raw"] = g["folded"]

    out_path.write_text(json.dumps(result, separators=(",", ":")))
    print(f"wrote {out_path} (epoch {epoch}, {len(result['nodes'])} nodes, "
          f"cases {sorted(set(c for n in result['nodes'].values() for c in n['cases']))}, "
          f"{out_path.stat().st_size // 1024} KB)")


if __name__ == "__main__":
    main()
