#!/bin/sh
# Builds a small release and wraps it as zig-out/ze.app, so Finder and
# `open` can launch it and open files with it.
set -eu
cd "$(dirname "$0")/.."
zig build --release
app=zig-out/ze.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp zig-out/bin/ze "$app/Contents/MacOS/ze"
cat > "$app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.hkay.ze</string>
  <key>CFBundleName</key><string>ze</string>
  <key>CFBundleExecutable</key><string>ze</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
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
codesign --force --sign - "$app"
echo "$app"
