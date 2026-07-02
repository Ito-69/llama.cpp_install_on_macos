#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

VERSION="2.3.0"
APP_NAME="LlamaMate"
BUILD_ARM64=".build/arm64/release"
BUILD_X86_64=".build/x86_64/release"
UNIVERSAL_DIR=".build"

echo "==> Building arm64 slice..."
swift build -c release --triple arm64-apple-macosx13.0 --scratch-path .build/arm64 --disable-sandbox

echo "==> Building x86_64 slice..."
swift build -c release --triple x86_64-apple-macosx13.0 --scratch-path .build/x86_64 --disable-sandbox

echo "==> Creating universal binary..."
lipo -create -output "${UNIVERSAL_DIR}/llmctl-universal" "${BUILD_ARM64}/llmctl" "${BUILD_X86_64}/llmctl"

mkdir -p "${APP_NAME}.app/Contents/MacOS"
cp "${UNIVERSAL_DIR}/llmctl-universal" "${APP_NAME}.app/Contents/MacOS/llmctl"

mkdir -p "${APP_NAME}.app/Contents/Resources"
cp Sources/llmctl/llama.png "${APP_NAME}.app/Contents/Resources/llama.png"
cp Sources/llmctl/llama.icns "${APP_NAME}.app/Contents/Resources/llama.icns"

# Bundle install-llama.sh for offline/portable use
if [[ -f "../install-llama.sh" ]]; then
  cp "../install-llama.sh" "${APP_NAME}.app/Contents/Resources/install-llama.sh"
fi

cat > "${APP_NAME}.app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>llmctl</string>
    <key>CFBundleIdentifier</key>
    <string>com.llamamate.app</string>
    <key>CFBundleName</key>
    <string>LlamaMate</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleIconFile</key>
    <string>llama</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
EOF

echo "==> Ad-hoc signing to reduce Gatekeeper friction..."
codesign --force --deep --sign - "${APP_NAME}.app"
xattr -dr com.apple.quarantine "${APP_NAME}.app" 2>/dev/null || true

echo ""
echo "  Built: ${APP_NAME}.app"
echo "  Drag to /Applications:"
echo "    cp -r \"${APP_NAME}.app\" /Applications/"
