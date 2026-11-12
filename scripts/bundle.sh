#!/bin/sh
# bundle.sh [dev|perf|stable] [out.app]: builds Zag and wraps it as a macOS
# .app bundle, then prints the bundle path.
#   dev     "Zag Dev", dev.hkay.ze.dev, at zig-out/Zag Dev.app. Runs in the
#           background (LSUIElement); start it with scripts/dev.sh.
#           ZE_DEBUG=1 builds in debug mode for full panic stack traces.
#   perf    "Zag Perf", dev.hkay.ze.perf, at zig-out/Zag Perf.app: release build
#           with the self-driving benchmark compiled in (scripts/bench.sh).
#   stable  "Zag", dev.hkay.ze, at zig-out/Zag.app.
#
# Environment:
#   CODESIGN_IDENTITY  Signing identity name, or "-" for ad-hoc signing.
#                      Defaults to "Vesper Self-Signed" when present in the
#                      keychain, otherwise "-" for local source builds.
#   ZE_VERSION         Short version string (default: 0.1.0).
#   ZIG                Zig compiler command (default: zig).
set -eu
cd "$(dirname "$0")/.."
flavor=${1:-dev}
case $flavor in
  dev) name="Zag Dev" id=dev.hkay.ze.dev ui="<key>LSUIElement</key><true/>" ;;
  perf) name="Zag Perf" id=dev.hkay.ze.perf ui="<key>LSUIElement</key><true/>" ;;
  stable) name=Zag id=dev.hkay.ze ui="" ;;
  *) echo "bundle.sh: dev, perf or stable, not $flavor" >&2; exit 1 ;;
esac
app=${2:-"zig-out/$name.app"}
zig_cmd=${ZIG:-zig}
version=${ZE_VERSION:-0.1.0}
build_ver=$(git rev-parse --short=9 HEAD 2>/dev/null || printf '%s' "$version")
if [ "$flavor" = dev ] && [ "${ZE_DEBUG:-}" = 1 ]; then "$zig_cmd" build
elif [ "$flavor" = perf ]; then "$zig_cmd" build --release -Dbench=true
else "$zig_cmd" build --release; fi
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp zig-out/bin/zag "$app/Contents/MacOS/zag"
# The icon. actool also writes a 1.9 MB Assets.car for macOS 26's glass
# modes; Zag ships only the 37 KB AppIcon.icns (up to 256 px), which every
# macOS shows in the same shape.
icon_sha=$(find "$PWD/AppIcon.icon" -type f | LC_ALL=C sort | xargs shasum -a 256 | shasum -a 256 | awk '{print $1}')
icon_cache="zig-out/.icon-cache/$icon_sha"
if [ ! -f "$icon_cache/AppIcon.icns" ]; then
  icon=$(mktemp -d)
  xcrun actool "$PWD/AppIcon.icon" --compile "$icon" --app-icon AppIcon \
    --platform macosx --minimum-deployment-target 15.0 \
    --output-partial-info-plist /dev/null >/dev/null
  mkdir -p "zig-out/.icon-cache"
  mv "$icon" "$icon_cache" 2>/dev/null || rm -rf "$icon"
fi
cp "$icon_cache/AppIcon.icns" "$app/Contents/Resources/"
cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$id</string>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundleDisplayName</key><string>$name</string>
  <key>CFBundleExecutable</key><string>zag</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$build_ver</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Harsha Kotcherlakota. MIT License.</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  $ui
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSItemContentTypes</key>
      <array><string>public.text</string><string>public.data</string><string>public.folder</string></array>
    </dict>
  </array>
</dict>
</plist>
EOF
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
  sign_id=$CODESIGN_IDENTITY
elif security find-identity -v -p codesigning 2>/dev/null | grep -Fq '"Vesper Self-Signed"'; then
  sign_id="Vesper Self-Signed"
else
  sign_id="-"
fi
case $sign_id in
  "Developer ID Application:"*)
    codesign --force --options runtime --timestamp --sign "$sign_id" "$app" ;;
  *)
    codesign --force --sign "$sign_id" "$app" ;;
esac
echo "$app"
