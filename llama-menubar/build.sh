#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="llama-menubar"
BUILD_DIR=".build/release"

swift build -c release --disable-sandbox

mkdir -p "${APP_NAME}.app/Contents/MacOS"
cp "${BUILD_DIR}/llmctl" "${APP_NAME}.app/Contents/MacOS/llmctl"

cat > "${APP_NAME}.app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>llmctl</string>
    <key>CFBundleIdentifier</key>
    <string>com.llama.menubar</string>
    <key>CFBundleName</key>
    <string>llama-menubar</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
EOF

echo ""
echo "  Built: ${APP_NAME}.app"
echo "  Drag to /Applications:"
echo "    cp -r \"${APP_NAME}.app\" /Applications/"
