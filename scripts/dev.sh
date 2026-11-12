#!/bin/sh
# dev.sh [build] [files...]: builds "Zag Dev" and starts a new copy of it in
# the background, behind every window, without taking the keys. Prints its
# pid. `dev.sh build` only builds. Its settings file lives under ZE_DEV_HOME
# (default /tmp/ze-dev-home) and its session in its own defaults
# (dev.hkay.ze.dev), never Harsha's. What it prints, panics included, goes
# to ZE_DEV_LOG (default /tmp/ze-dev.log). ZE_DEBUG=1 makes a debug build.
# Harsha's own Zag is the stable one at ~/Applications/Zag.app; only Ship it
# changes that (scripts/ship.sh).
set -eu
# `open` starts the app in /, so paths are made absolute from here first.
here=$PWD
cd "$(dirname "$0")/.."
app="$PWD/zig-out/Zag Dev.app"
qm with build zag -- mise exec zig@0.17.0 -- scripts/bundle.sh dev "$app" >/dev/null
[ "${1:-}" = build ] && { echo "$app"; exit 0; }
home=${ZE_DEV_HOME:-/tmp/ze-dev-home}
mkdir -p "$home"
for a; do
  case $a in /*) ;; *) a="$here/$a" ;; esac
  set -- "$@" "$a"
  shift
done
log=${ZE_DEV_LOG:-/tmp/ze-dev.log}
pat="^$app/Contents/MacOS/zag( |\$)"
# Copies already running before `open` aren't the new one.
before=" $(pgrep -f "$pat" | tr '\n' ' ') "
open -g -j -n "$app" --env HOME="$home" --stdout "$log" --stderr "$log" --args "$@"
# Launch Services can take seconds under load, so wait up to 10 s.
i=0
while [ $i -lt 200 ]; do
  pid=$(pgrep -n -f "$pat" || true)
  case $before in *" $pid "*) ;; *) echo "$pid"; exit 0 ;; esac
  sleep 0.05
  i=$((i + 1))
done
echo "dev.sh: Zag Dev didn't start within 10 s; see $log" >&2
exit 1
