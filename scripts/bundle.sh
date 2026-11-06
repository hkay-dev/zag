#!/bin/sh
# bundle.sh [dev|stable] [out.app]: builds a small release and wraps it as an
# app, signed with Vesper Self-Signed, and prints the app's path.
#   dev     "Zag Dev", dev.hkay.ze.dev, at zig-out/Zag Dev.app. It runs in the
#           background (LSUIElement); start it with scripts/dev.sh.
#           ZE_DEBUG=1 builds it in debug mode, which stops on bad memory
#           use with a message instead of drawing garbage or crashing later.
#   stable  "Zag", dev.hkay.ze, at zig-out/Zag.app. Only scripts/ship.sh makes
#           it, and installs it at ~/Applications/Zag.app.
#   perf    "Zag Perf", dev.hkay.ze.perf, at zig-out/Zag Perf.app: the same
#           release with the self-driving bench compiled in, for
#           scripts/bench.sh. Background only, like dev.
# The bundle ids still say ze, the app's first name, so settings, sessions
# and drafts carry over from it.
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
if [ "$flavor" = dev ] && [ "${ZE_DEBUG:-}" = 1 ]; then zig build
elif [ "$flavor" = perf ]; then zig build --release -Dbench=true
else zig build --release; fi
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp zig-out/bin/zag "$app/Contents/MacOS/zag"
# The icon. actool also writes a 1.9 MB Assets.car for macOS 26's glass
# modes; Zag ships only the 37 KB AppIcon.icns (up to 256 px), which every
# macOS shows in the same shape.
icon=$(mktemp -d)
xcrun actool "$PWD/AppIcon.icon" --compile "$icon" --app-icon AppIcon \
  --platform macosx --minimum-deployment-target 15.0 \
  --output-partial-info-plist /dev/null >/dev/null
cp "$icon/AppIcon.icns" "$app/Contents/Resources/"
rm -rf "$icon"
cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$id</string>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundleExecutable</key><string>zag</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>$(git rev-parse --short=9 HEAD)</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
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
# One identity for stable and dev, never ad hoc: macOS keeps grants per
# bundle id and certificate (armada docs/mac-dev-builds.md).
codesign --force --sign "Vesper Self-Signed" "$app"
echo "$app"
