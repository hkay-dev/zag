#!/bin/sh
# dmg.sh [out.dmg] [in.app]: builds Zag.app (unless an existing .app is passed)
# and packages it with an /Applications shortcut into a compressed macOS .dmg.
#
# Environment:
#   CODESIGN_IDENTITY  Signing identity for Zag.app and the .dmg. Uses
#                      "Vesper Self-Signed" when available in the keychain,
#                      otherwise "-" (ad-hoc) for local builds.
#   ZE_VERSION         Release version string (default: 0.1.0).
#   ZIG                Zig compiler command (default: zig).
set -eu
cd "$(dirname "$0")/.."

version=${ZE_VERSION:-0.1.0}
dmg=${1:-"zig-out/Zag-$version-arm64.dmg"}
app=${2:-""}

if [ -z "$app" ]; then
  app=$(./scripts/bundle.sh stable "zig-out/Zag.app")
elif [ ! -d "$app" ]; then
  echo "dmg.sh: app bundle not found: $app" >&2
  exit 1
fi

mkdir -p "$(dirname "$dmg")"
rm -f "$dmg"

built_with_dmgbuild=0
if command -v python3 >/dev/null 2>&1; then
  venv="zig-out/.dmgbuild"
  if [ ! -x "$venv/bin/dmgbuild" ]; then
    python3 -m venv "$venv" >/dev/null 2>&1 || true
    if [ -x "$venv/bin/pip" ]; then
      "$venv/bin/pip" install --quiet --disable-pip-version-check dmgbuild==1.6.7 >/dev/null 2>&1 || true
    fi
  fi
  if [ -x "$venv/bin/dmgbuild" ]; then
    "$venv/bin/dmgbuild" -s dmg/settings.py -D app="$app" "Zag" "$dmg"
    built_with_dmgbuild=1
  fi
fi

if [ "$built_with_dmgbuild" -eq 0 ]; then
  stage=$(mktemp -d "${TMPDIR:-/tmp}/zag-dmg.XXXXXX")
  trap 'rm -rf "$stage"' EXIT
  cp -R "$app" "$stage/Zag.app"
  ln -s /Applications "$stage/Applications"
  hdiutil create -volname "Zag" -srcfolder "$stage" -ov -format UDZO "$dmg" >/dev/null
  rm -rf "$stage"
  trap - EXIT
fi

if [ -n "${CODESIGN_IDENTITY:-}" ]; then
  sign_id=$CODESIGN_IDENTITY
elif security find-identity -v -p codesigning 2>/dev/null | grep -Fq '"Vesper Self-Signed"'; then
  sign_id="Vesper Self-Signed"
else
  sign_id="-"
fi

if [ "$sign_id" != "-" ]; then
  case $sign_id in
    "Developer ID Application:"*)
      codesign --force --timestamp --sign "$sign_id" "$dmg" ;;
    *)
      codesign --force --sign "$sign_id" "$dmg" ;;
  esac
  codesign --verify --strict "$dmg"
fi

hdiutil verify -quiet "$dmg"
echo "$dmg"
