#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

# Build the menu bar app and package it for GitHub Releases
VERSION="${1:-2.0.0}"
OUTDIR="release-out"

rm -rf "$OUTDIR"
mkdir -p "$OUTDIR"

# Build the app
echo "==> Building LlamaMate.app..."
(cd llamamate && ./build.sh)

# Create the release DMG
echo "==> Packaging LlamaMate.dmg..."
TMP_DIR=$(mktemp -d)
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

ln -s /Applications "$TMP_DIR/Applications"
cp -R "llamamate/LlamaMate.app" "$TMP_DIR/LlamaMate.app"

hdiutil create -volname "LlamaMate v$VERSION" \
  -srcfolder "$TMP_DIR" \
  -ov -format UDZO \
  "$OUTDIR/LlamaMate-$VERSION.dmg"

echo ""
echo "  Release ready: $OUTDIR/"
echo "    - LlamaMate-$VERSION.dmg"
echo ""
echo "  Upload to GitHub Releases."
