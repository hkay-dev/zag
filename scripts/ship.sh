#!/usr/bin/env bash
# Ship it: builds stable Zag from this commit and installs it at
# ~/Applications/Zag.app. The script quits a running Zag and opens the new
# build. Use scripts/dev.sh for development builds instead.
set -euo pipefail
cd "$(dirname "$0")/.."

. "$(command -v armada-ship-lib.sh)" || { echo "ship: armada-ship-lib.sh is not on PATH" >&2; exit 1; }
name=Zag
project=zag
identity="Vesper Self-Signed"
dest_dir="$HOME/Applications"
root="$PWD"
ship_lock
ship_check_clean
ship_check_identity
ship_stage
echo "::step Build the app"
ship_build mise exec zig@0.17.0 -- scripts/bundle.sh stable "$app"
ship_check_requirement

ship_install
echo "installed Zag $(echo "$commit" | cut -c1-7) at $dest_dir/$name.app"
