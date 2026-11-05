#!/bin/sh
# dev.sh [build] [files...]: builds "ze Dev" and starts a new copy of it in
# the background, behind every window, without taking the keys. Prints its
# pid. `dev.sh build` only builds. Settings and the session live under
# ZE_DEV_HOME (default /tmp/ze-dev-home), never Harsha's.
# Harsha's own ze is the stable one at ~/Applications/ze.app; only Ship it
# changes that (scripts/ship.sh).
set -eu
# `open` starts the app in /, so paths are made absolute from here first.
here=$PWD
cd "$(dirname "$0")/.."
app="$PWD/zig-out/ze Dev.app"
qm with build zig-editor -- mise exec zig@0.17.0 -- scripts/bundle.sh dev "$app" >/dev/null
[ "${1:-}" = build ] && { echo "$app"; exit 0; }
home=${ZE_DEV_HOME:-/tmp/ze-dev-home}
mkdir -p "$home"
for a; do
  case $a in /*) ;; *) a="$here/$a" ;; esac
  set -- "$@" "$a"
  shift
done
open -g -j -n "$app" --env HOME="$home" --args "$@"
sleep 1
pgrep -n -f "$app/Contents/MacOS/ze"
