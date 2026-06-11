#!/usr/bin/env bash
set -euo pipefail

# Build the Metal shader library (default.metallib) from source .metal files.
#
# Prerequisites: Xcode Command Line Tools or Xcode.app
#
# Usage:
#   ./script/build-metallib.sh
#
# Output: MetalSplatter/Resources/default.metallib

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOURCES_DIR="$ROOT_DIR/MetalSplatter/Resources"
TEMP_DIR=$(mktemp -d)

echo "→ Compiling Metal shaders from: $RESOURCES_DIR"

for f in "$RESOURCES_DIR"/*.metal; do
    base="$(basename "$f" .metal)"
    echo "   $base"
    xcrun -sdk macosx metal \
        -c \
        -I "$RESOURCES_DIR" \
        "$f" \
        -o "$TEMP_DIR/$base.air"
done

echo "→ Linking into metallib: $RESOURCES_DIR/default.metallib"

xcrun -sdk macosx metallib \
    "$TEMP_DIR"/*.air \
    -o "$RESOURCES_DIR/default.metallib"

rm -rf "$TEMP_DIR"

echo "✓ Done: $RESOURCES_DIR/default.metallib"
file "$RESOURCES_DIR/default.metallib"
