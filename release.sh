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

# Create the release zip
echo "==> Packaging llama-menubar.zip..."
ditto -c -k --sequesterRsrc --keepParent \
  "llama-menubar/llama-menubar.app" \
  "$OUTDIR/llama-menubar-$VERSION.zip"

echo ""
echo "  Release ready: $OUTDIR/"
echo "    - llama-menubar-$VERSION.zip"
echo ""
echo "  Upload to GitHub Releases."
