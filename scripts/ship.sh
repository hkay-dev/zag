#!/usr/bin/env bash
# Ship it (`deckhand ship run zag`): builds the stable "Zag" from this commit
# and installs it at ~/Applications/Zag.app, the only copy Harsha runs. A
# running Zag is quit and opened again on the new build. Only Ship it runs
# this; agents test "Zag Dev" from scripts/dev.sh.
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
