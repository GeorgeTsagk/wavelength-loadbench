#!/usr/bin/env bash
# Give both daemons an exact-bracket CPU profile: /debug/cpu/start and
# /debug/cpu/stop on their existing pprof listeners. The stock net/http/pprof
# handler only offers ?seconds=N, which cannot line up with an operation whose
# duration is unknown until it ends: too short truncates, too long bleeds into
# the next case. The seconds parameter on start is kept as a watchdog so a
# harness that dies mid-case cannot leave the profiler running.
#
# The patch is one new self-contained file per repo plus a one-line
# registration call inserted after the stock trace-handler registration (a
# boilerplate line identical in both repos). It is committed on a local
# branch `bench-pprof` in each checkout; config.env pins those commits.
# The lumos repo is private: its bench-pprof branch must NEVER be pushed.
#
# Idempotent: re-running on an already-patched checkout is a no-op.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set -a; . "$HERE/config.env"; set +a
export PATH=$PATH:/usr/local/go/bin

write_handlers_file() {
  local pkg=$1 out=$2
  cat > "$out" <<EOF
package $pkg

// Bench-harness CPU profile bracket. Added by wavelength-loadbench
// bench/patch-pprof.sh on a local branch; not upstream code.

import (
	"fmt"
	"net/http"
	"os"
	rtpprof "runtime/pprof"
	"strconv"
	"sync"
	"time"
)

var benchCPU struct {
	mu   sync.Mutex
	file *os.File
	stop *time.Timer
}

func benchCPUStopLocked() {
	if benchCPU.file == nil {
		return
	}
	rtpprof.StopCPUProfile()
	if benchCPU.stop != nil {
		benchCPU.stop.Stop()
		benchCPU.stop = nil
	}
}

// registerBenchCPUHandlers adds an explicit start/stop CPU profile pair so a
// profile window can be bracketed to exactly one operation.
func registerBenchCPUHandlers(mux *http.ServeMux) {
	mux.HandleFunc(
		"/debug/cpu/start",
		func(w http.ResponseWriter, r *http.Request) {
			benchCPU.mu.Lock()
			defer benchCPU.mu.Unlock()
			if benchCPU.file != nil {
				http.Error(w, "already profiling", 409)
				return
			}
			f, err := os.CreateTemp("", "bench-cpu-*.pb.gz")
			if err != nil {
				http.Error(w, err.Error(), 500)
				return
			}
			if err := rtpprof.StartCPUProfile(f); err != nil {
				_ = f.Close()
				_ = os.Remove(f.Name())
				http.Error(w, err.Error(), 500)
				return
			}
			benchCPU.file = f
			watchdog := 30 * time.Minute
			if v := r.URL.Query().Get("seconds"); v != "" {
				if n, err := strconv.Atoi(v); err == nil {
					watchdog = time.Duration(n) *
						time.Second
				}
			}
			benchCPU.stop = time.AfterFunc(watchdog, func() {
				benchCPU.mu.Lock()
				defer benchCPU.mu.Unlock()
				benchCPUStopLocked()
			})
			fmt.Fprintln(w, "started")
		},
	)
	mux.HandleFunc(
		"/debug/cpu/stop",
		func(w http.ResponseWriter, r *http.Request) {
			benchCPU.mu.Lock()
			f := benchCPU.file
			benchCPUStopLocked()
			benchCPU.file = nil
			benchCPU.mu.Unlock()
			if f == nil {
				http.Error(w, "not profiling", 409)
				return
			}
			name := f.Name()
			_ = f.Close()
			defer func() { _ = os.Remove(name) }()
			http.ServeFile(w, r, name)
		},
	)
}
EOF
  gofmt -w "$out"
}

patch_repo() {
  local src=$1 base_rev=$2 pkg=$3 target_dir=$4 hook_file=$5
  cd "$src"

  if git rev-parse -q --verify bench-pprof >/dev/null; then
    git checkout -q bench-pprof
    echo "$src: bench-pprof exists at $(git rev-parse --short=8 HEAD)"
    return
  fi

  [[ "$(git rev-parse --short=8 HEAD)" == "$base_rev" ]] \
    || { echo "FATAL: $src not at pinned base $base_rev" >&2; exit 1; }
  git checkout -q -b bench-pprof

  write_handlers_file "$pkg" "$target_dir/bench_cpu_handlers.go"

  # Register the handlers right after the stock trace handler registration,
  # inside the same mux-building function. This anchor line is standard
  # net/http/pprof boilerplate present verbatim in both repos.
  python3 - "$hook_file" <<'PY'
import re, sys
path = sys.argv[1]
src = open(path).read()
if "registerBenchCPUHandlers" not in src:
    m = re.search(r'\n(\tmux\.HandleFunc\(\n?[^\n]*"/debug/pprof/trace"[^\n]*\n(?:[^\n]*\n)?)', src)
    assert m, "trace handler registration not found in " + path
    anchor = m.group(1)
    src = src.replace(anchor, anchor + "\tregisterBenchCPUHandlers(mux)\n", 1)
    open(path, "w").write(src)
    print("hooked " + path)
PY

  gofmt -l "$hook_file" >/dev/null
  go build ./... >/dev/null 2>&1 || GOTOOLCHAIN=auto go build "./$(dirname "$hook_file")/..." \
    || { echo "FATAL: patched $src does not build" >&2; exit 1; }

  git add "$target_dir/bench_cpu_handlers.go" "$hook_file"
  git commit -q -m "bench: add exact-bracket CPU profile handlers (local only)"
  echo "$src: bench-pprof created at $(git rev-parse --short=8 HEAD)"
}

patch_repo "$LUMOS_SRC" "$LUMOS_REV" pprof pprof pprof/server.go
patch_repo "$WAVELENGTH_SRC" "$WAVELENGTH_REV" waved waved waved/pprof.go

echo
echo "update config.env pins to:"
echo "  LUMOS_BENCH_REV=$(git -C "$LUMOS_SRC" rev-parse --short=8 bench-pprof)"
echo "  WAVELENGTH_BENCH_REV=$(git -C "$WAVELENGTH_SRC" rev-parse --short=8 bench-pprof)"
