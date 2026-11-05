#!/bin/sh
# bench.sh: ze's perf harness (the zig-editor-perf skill has the loop).
#   bench.sh build [out.app]       builds "ze Perf" (release plus src/bench.zig)
#                                  from this checkout; prints the app's path.
#   bench.sh run APP OUT [N]       launches APP N times (default 1) in the
#                                  background; each launch appends one number
#                                  per step to OUT/<metric>.txt and quits.
#   bench.sh session APP OUT [N]   launches APP N times on a copy of Harsha's
#                                  own ze session and drafts, records launch
#                                  time and memory only, and quits without
#                                  touching a file.
# Each run launch gets a fresh HOME and session, and opens the same frozen copy
# of ze's sources (ZE_BENCH_DATA, made once from commit 7132176), so two
# builds see the same files. Nothing takes focus. Time it inside
# `qm with quiet`.
set -eu
cd "$(dirname "$0")/.."
data=${ZE_BENCH_DATA:-$HOME/.local/share/zig-editor-perf/data}
case ${1:-} in
  build)
    app=${2:-"$PWD/zig-out/ze Perf.app"}
    qm with build zig-editor -- nice mise exec zig@0.17.0 -- scripts/bundle.sh perf "$app" >/dev/null
    echo "$app" ;;
  run|session)
    mode=$1 app=$2 out=$3 n=${4:-1}
    files="$data/src/view.zig:$data/src/editor.zig:$data/src/buffer.zig:$data/src/syntax.zig:$data/src/settings.zig"
    if [ ! -d "$data/src" ]; then
      mkdir -p "$data"
      git archive 7132176 src | tar -x -C "$data"
    fi
    mkdir -p "$out"
    i=0
    while [ "$i" -lt "$n" ]; do
      home=$(mktemp -d /tmp/ze-bench-home.XXXXXX)
      defaults delete dev.hkay.ze.perf >/dev/null 2>&1 || true
      if [ "$mode" = session ]; then
        defaults export dev.hkay.ze - | defaults import dev.hkay.ze.perf -
        mkdir -p "$home/Library/Application Support/ze"
        cp -R "$HOME/Library/Application Support/ze/Drafts" "$home/Library/Application Support/ze/" 2>/dev/null || true
        cp -R "$HOME/.config/ze" "$home/.config/" 2>/dev/null || { mkdir -p "$home/.config" && cp -R "$HOME/.config/ze" "$home/.config/"; }
        open -W -g -j -n "$app" --env HOME="$home" --env ZE_BENCH="$out" --env ZE_BENCH_LAUNCH_ONLY=1 \
          --stdout "$out/log.txt" --stderr "$out/log.txt"
      else
        open -W -g -j -n "$app" --env HOME="$home" --env ZE_BENCH="$out" --env ZE_BENCH_HOLD="${ZE_BENCH_HOLD:-0}" \
          --env ZE_BENCH_ROOT="$data" --env ZE_BENCH_FILES="$files" \
          --stdout "$out/log.txt" --stderr "$out/log.txt"
      fi
      rm -rf "$home"
      i=$((i + 1))
    done ;;
  *) echo "usage: bench.sh build [out.app] | run APP OUT [N] | session APP OUT [N]" >&2; exit 1 ;;
esac
