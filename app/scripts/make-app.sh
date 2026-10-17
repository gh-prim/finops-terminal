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
cat > "$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.finops.terminal</string>
  <key>CFBundleName</key><string>finops-terminal</string>
  <key>CFBundleExecutable</key><string>FinopsTerminal</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$bundle" >/dev/null
echo "$bundle"
