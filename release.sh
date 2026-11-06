#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

# Build the menu bar app and package it for GitHub Releases.
#
# The single source of truth for the version is VERSION in llamamate/build.sh.
# An optional argument may be passed, but it must match that version — this
# guards against tagging/packaging a DMG whose embedded CFBundleVersion differs
# from the filename.
BUILD_SH_VERSION="$(sed -n 's/^VERSION="\(.*\)"/\1/p' llamamate/build.sh | head -1)"
if [[ -z "$BUILD_SH_VERSION" ]]; then
  echo "ERROR: could not read VERSION from llamamate/build.sh" >&2
  exit 1
fi

VERSION="${1:-$BUILD_SH_VERSION}"
if [[ "$VERSION" != "$BUILD_SH_VERSION" ]]; then
  echo "ERROR: requested version '$VERSION' does not match llamamate/build.sh VERSION='$BUILD_SH_VERSION'." >&2
  echo "       Bump VERSION in llamamate/build.sh first, then run: bash release.sh" >&2
  exit 1
fi

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
