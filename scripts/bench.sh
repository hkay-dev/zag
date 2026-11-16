#!/bin/sh
# bench.sh: Zag's perf harness (the zag-perf skill has the loop).
#   bench.sh build [out.app]       builds "Zag Perf" (release plus src/bench.zig)
#                                  from this checkout; prints the app's path.
#   bench.sh run APP OUT [N]       launches APP N times (default 1) in the
#                                  background; each launch appends one number
#                                  per step to OUT/<metric>.txt and quits.
#   bench.sh session APP OUT [N]   launches APP N times on a copy of Harsha's
#                                  own Zag session and drafts, records launch
#                                  time and memory only, and quits without
#                                  touching a file.
#   bench.sh ab A B OUT [N]        runs A then B once each, N rounds (default
#                                  6), into OUT/a and OUT/b, with one
#                                  `qm with quiet zag-perf` hold per pair when
#                                  qm (a local build queue) is installed.
# Each run launch gets a fresh HOME and session, and opens the same frozen copy
# of Zag's sources (ZE_BENCH_DATA, made once from commit 7132176), so two
# builds see the same files. The last step, quickopen_ms (open quick open, type
# three letters, close), points quick open at a home-shaped folder of about
# 60k files (ZE_BENCH_HOME_DATA, made once by this script, never in Git) and
# puts the root back after. Nothing takes focus. Time `run` and `session`
# inside `qm with quiet`, one A/B pair per hold (`ab` does this): qm stops a
# hold past 10 minutes when a build waits. Without qm or mise, the script runs
# each command directly with the zig on PATH.
set -eu
cd "$(dirname "$0")/.."
zig_env=""; command -v mise >/dev/null 2>&1 && zig_env="mise exec zig@0.17.0 --"
hold() { if command -v qm >/dev/null 2>&1; then qm with "$@"; else shift 3; "$@"; fi; }
data=${ZE_BENCH_DATA:-$HOME/.local/share/zig-editor-perf/data}
homedata=${ZE_BENCH_HOME_DATA:-$HOME/.local/share/zig-editor-perf/home}
# A home-shaped tree of empty files: a deep Library (caches, app support,
# containers), Documents, Development with node_modules, a hidden .cache.
# Seeded, so every machine and every run gets the same tree.
make_home() {
  rm -rf "$homedata"
  mkdir -p "$homedata"
  python3 - "$homedata" <<'PY'
import os, random, sys
root = sys.argv[1]
rng = random.Random(1105)
words = ("cache data store index logs tmp session state blob chunk asset image font plugin module config "
         "prefs sync backup thumb media video audio text docs notes draft report mail contact event model "
         "shader update crash trace temp meta lib bin res").split()
exts = ("json plist db sqlite log txt png jpg cache dat bin js swift md pdf").split()
def mk(base, count, max_depth, per_dir):
    # Grow a random tree of count/per_dir folders under base (none deeper than
    # max_depth), then drop count empty files into random folders of it.
    dirs = [(os.path.join(root, base), 0)]
    os.makedirs(dirs[0][0], exist_ok=True)
    while len(dirs) < count // per_dir:
        parent, depth = dirs[rng.randrange(len(dirs))]
        if depth >= max_depth:
            continue
        d = os.path.join(parent, "%s%d" % (rng.choice(words), rng.randrange(1000)))
        if not os.path.isdir(d):
            os.mkdir(d)
            dirs.append((d, depth + 1))
    for _ in range(count):
        d = dirs[rng.randrange(len(dirs))][0]
        open(os.path.join(d, "%s%d.%s" % (rng.choice(words), rng.randrange(10**6), rng.choice(exts))), "w").close()
mk("Library/Caches", 14000, 7, 8)
mk("Library/Application Support", 12000, 8, 8)
mk("Library/Containers", 14000, 9, 8)
mk("Library/Group Containers", 3000, 6, 8)
mk("Library/Mobile Documents", 3000, 5, 8)
mk("Documents", 6000, 4, 10)
mk("Development", 9000, 6, 10)
mk("Development/app/node_modules", 9000, 6, 10)
mk("Pictures", 3000, 3, 20)
mk("Downloads", 1000, 1, 30)
mk(".cache", 5000, 5, 8)
open(os.path.join(root, ".done"), "w").close()
PY
}
case ${1:-} in
  build)
    app=${2:-"$PWD/zig-out/Zag Perf.app"}
    hold build zag -- nice $zig_env scripts/bundle.sh perf "$app" >/dev/null
    echo "$app" ;;
  ab)
    a=$2 b=$3 out=$4 n=${5:-6} k=0
    while [ "$k" -lt "$n" ]; do
      hold quiet zag-perf -- sh -c 'scripts/bench.sh run "$1" "$3/a" 1 && scripts/bench.sh run "$2" "$3/b" 1' sh "$a" "$b" "$out"
      k=$((k + 1))
    done ;;
  run|session)
    mode=$1 app=$2 out=$3 n=${4:-1}
    files="$data/src/view.zig:$data/src/editor.zig:$data/src/buffer.zig:$data/src/syntax.zig:$data/src/settings.zig"
    if [ ! -d "$data/src" ]; then
      mkdir -p "$data"
      git archive 7132176 src | tar -x -C "$data"
    fi
    mkdir -p "$out"
    [ "$mode" = run ] && [ ! -e "$homedata/.done" ] && make_home
    i=0
    while [ "$i" -lt "$n" ]; do
      home=$(mktemp -d /tmp/ze-bench-home.XXXXXX)
      defaults delete dev.hkay.ze.perf >/dev/null 2>&1 || true
      if [ "$mode" = session ]; then
        defaults export dev.hkay.ze - | defaults import dev.hkay.ze.perf -
        mkdir -p "$home/Library/Application Support/ze"
        cp -R "$HOME/Library/Application Support/ze/Drafts" "$home/Library/Application Support/ze/" 2>/dev/null || true
        mkdir -p "$home/.config"; cp -R "$HOME/.config/zag" "$home/.config/" 2>/dev/null || true
        open -W -g -j -n "$app" --env HOME="$home" --env ZE_BENCH="$out" --env ZE_BENCH_LAUNCH_ONLY=1 \
          --stdout "$out/log.txt" --stderr "$out/log.txt"
      else
        if [ "${ZE_BENCH_WRAP:-0}" = 1 ]; then
          mkdir -p "$home/.config/zag"
          printf 'wrap = true\n' > "$home/.config/zag/config.toml"
        fi
        open -W -g -j -n "$app" --env HOME="$home" --env ZE_BENCH="$out" --env ZE_BENCH_HOLD="${ZE_BENCH_HOLD:-0}" \
          --env ZE_BENCH_ROOT="$data" --env ZE_BENCH_QUICKOPEN_ROOT="$homedata" --env ZE_BENCH_FILES="$files" \
          --stdout "$out/log.txt" --stderr "$out/log.txt"
      fi
      rm -rf "$home"
      i=$((i + 1))
    done ;;
  *) echo "usage: bench.sh build [out.app] | run APP OUT [N] | session APP OUT [N] | ab A B OUT [N]" >&2; exit 1 ;;
esac
