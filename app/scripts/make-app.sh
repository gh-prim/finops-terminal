#!/bin/zsh
# Builds FinopsTerminal and wraps it in a development .app bundle at app/build/.
# The bundle finds the gateway through the source path baked in at compile time
# (override with FINOPS_GATEWAY_DIR).
set -euo pipefail
cd "${0:A:h}/.."

config="${1:-debug}"
swift build -c "$config"

bundle="build/finops-terminal.app"
rm -rf "$bundle"
mkdir -p "$bundle/Contents/MacOS"
cp ".build/$config/FinopsTerminal" "$bundle/Contents/MacOS/FinopsTerminal"

# App icon: design/icon-mac-1024.png (from scripts/make_icon.swift) → AppIcon.icns
icon_src="../design/icon-mac-1024.png"
if [[ -f "$icon_src" ]]; then
  iconset=$(mktemp -d)/AppIcon.iconset
  mkdir -p "$iconset"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$icon_src" --out "$iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$icon_src" --out "$iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  mkdir -p "$bundle/Contents/Resources"
  iconutil -c icns "$iconset" -o "$bundle/Contents/Resources/AppIcon.icns"
fi
cat > "$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.finops.terminal</string>
  <key>CFBundleName</key><string>finops-terminal</string>
  <key>CFBundleExecutable</key><string>FinopsTerminal</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$bundle" >/dev/null
echo "$bundle"
