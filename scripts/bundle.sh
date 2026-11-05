#!/bin/sh
# bundle.sh [dev|stable] [out.app]: builds a small release and wraps it as an
# app, signed with Vesper Self-Signed, and prints the app's path.
#   dev     "ze Dev", dev.hkay.ze.dev, at zig-out/ze Dev.app. It runs in the
#           background (LSUIElement); start it with scripts/dev.sh.
#           ZE_DEBUG=1 builds it in debug mode, which stops on bad memory
#           use with a message instead of drawing garbage or crashing later.
#   stable  "ze", dev.hkay.ze, at zig-out/ze.app. Only scripts/ship.sh makes
#           it, and installs it at ~/Applications/ze.app.
set -eu
cd "$(dirname "$0")/.."
flavor=${1:-dev}
case $flavor in
  dev) name="ze Dev" id=dev.hkay.ze.dev ui="<key>LSUIElement</key><true/>" ;;
  stable) name=ze id=dev.hkay.ze ui="" ;;
  *) echo "bundle.sh: dev or stable, not $flavor" >&2; exit 1 ;;
esac
app=${2:-"zig-out/$name.app"}
if [ "$flavor" = dev ] && [ "${ZE_DEBUG:-}" = 1 ]; then zig build; else zig build --release; fi
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp zig-out/bin/ze "$app/Contents/MacOS/ze"
# The icon. actool also writes a 1.9 MB Assets.car for macOS 26's glass
# modes; ze ships only the 37 KB AppIcon.icns (up to 256 px), which every
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
  <key>CFBundleExecutable</key><string>ze</string>
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
