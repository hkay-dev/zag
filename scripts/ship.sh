#!/usr/bin/env bash
# Ship it: builds stable Zag from this commit and installs it at
# /Applications/Zag.app. The script quits a running Zag and opens the new
# build. Use scripts/dev.sh for development builds instead.
set -euo pipefail
cd "$(dirname "$0")/.."

. "$(command -v armada-ship-lib.sh)" || { echo "ship: armada-ship-lib.sh is not on PATH" >&2; exit 1; }
name=Zag
project=zag
identity="Vesper Self-Signed"
dest_dir=/Applications
root="$PWD"
ship_lock
ship_check_clean
ship_check_identity
ship_stage
echo "::step Build the app"
ship_build mise exec zig@0.17.0 -- scripts/bundle.sh stable "$app"
# Ship it installed Zag in ~/Applications until 2026-11-18. Finder's Open With
# > Other... starts in /Applications, so this ship removes the old copy.
old="$HOME/Applications/$name.app"
if [[ ! -d $dest_dir/$name.app && -d $old ]]; then dest_dir="$HOME/Applications" ship_check_requirement
else ship_check_requirement; fi
reopen=0
if [[ -d $old ]]; then
  if [[ ${FOUNDRY_SHIP_STAGED:-${ARMADA_SHIP_STAGED:-}} != 1 ]] && pgrep -f "$old/Contents/MacOS/" >/dev/null 2>&1; then
    reopen=1
    echo "ship: the old $name in ~/Applications is running, quitting it"
    osascript -e "tell application id \"dev.hkay.ze\" to quit" >/dev/null 2>&1 || true
    for _ in $(seq 20); do pgrep -f "$old/Contents/MacOS/" >/dev/null 2>&1 || break; sleep 0.5; done
  fi
  if ship_in_use "$old"; then
    reopen=0
    echo "ship: the old $old is still running; delete it after it quits" >&2
  else
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$old" || true
    rm -rf "$old"
    echo "ship: removed the old $old"
  fi
fi

ship_install
[[ $reopen == 0 ]] || open -g -j "$dest_dir/$name.app"
echo "installed Zag $(echo "$commit" | cut -c1-7) at $dest_dir/$name.app"
