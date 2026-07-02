#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

# Build the menu bar app and package it for GitHub Releases
VERSION="${1:-2.0.0}"
OUTDIR="release-out"

rm -rf "$OUTDIR"
mkdir -p "$OUTDIR"

# Build the app
echo "==> Building llama-menubar.app..."
(cd llama-menubar && ./build.sh)

# Create the release DMG
echo "==> Packaging llama-menubar.dmg..."
TMP_DIR=$(mktemp -d)
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

ln -s /Applications "$TMP_DIR/Applications"
cp -R "llama-menubar/llama-menubar.app" "$TMP_DIR/llama-menubar.app"

hdiutil create -volname "llama-menubar v$VERSION" \
  -srcfolder "$TMP_DIR" \
  -ov -format UDZO \
  "$OUTDIR/llama-menubar-$VERSION.dmg"

echo ""
echo "  Release ready: $OUTDIR/"
echo "    - llama-menubar-$VERSION.dmg"
echo ""
echo "  Upload to GitHub Releases."
