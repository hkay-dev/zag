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

# Zag was called ze until 2026-11-05 and lived at ~/Applications/ze.app,
# with the same bundle id. The first Zag ship quits that copy, removes it
# and opens Zag in its place. Delete this block once ze.app is gone.
old="$dest_dir/ze.app"
ze_ran=0
if [[ -d $old ]]; then
    echo "::step Retire ze.app"
    if pgrep -f "$old/Contents/MacOS/" >/dev/null 2>&1; then
        ze_ran=1
        osascript -e 'tell application "ze" to quit' >/dev/null 2>&1 || true
        waited=0
        while pgrep -f "$old/Contents/MacOS/" >/dev/null 2>&1 && ((waited < 20)); do sleep 0.5; ((waited++)); done
    fi
    if pgrep -f "$old/Contents/MacOS/" >/dev/null 2>&1; then
        echo "ship: ze didn't quit in 10 s, so ze.app stays until the next ship"
        ze_ran=0
    else
        rm -rf "${old:?}"
        echo "ship: removed $old"
    fi
fi

ship_install
if [[ $ze_ran == 1 ]] && ! pgrep -f "$dest_dir/$name.app/Contents/MacOS/" >/dev/null 2>&1; then
    open -g -j "$dest_dir/$name.app"
fi
echo "installed Zag $(echo "$commit" | cut -c1-7) at $dest_dir/$name.app"
