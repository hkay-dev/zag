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
open -g -j -n "$app" --env HOME="$home" --stdout "${ZE_DEV_LOG:-/tmp/ze-dev.log}" --stderr "${ZE_DEV_LOG:-/tmp/ze-dev.log}" --args "$@"
sleep 1
pgrep -n -f "^$app/Contents/MacOS/zag( |\$)"
