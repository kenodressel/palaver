#!/bin/sh
# Fetch FluidAudio's NemoTextProcessing xcframework (SwiftPM hangs on it here).
# Usage: tools/fetch_nemo.sh DEST   (DEST is the folder that will hold NemoTextProcessing.xcframework)
set -eu
DEST="${1:?usage: fetch_nemo.sh DEST}"
URL="https://github.com/FluidInference/text-processing-rs/releases/download/v0.3.1/NemoTextProcessing.xcframework.zip"
SHA256="5fa8c10d4ec26c1bb2413125f351a7222a4c68a23b74476680fbada7e26fc6aa"

[ -d "$DEST/NemoTextProcessing.xcframework" ] && exit 0
mkdir -p "$DEST"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fsSL --retry 3 -o "$TMP/nemo.zip" "$URL"
GOT="$(shasum -a 256 "$TMP/nemo.zip" | cut -d' ' -f1)"
[ "$GOT" = "$SHA256" ] || { echo "✗ NemoTextProcessing checksum mismatch: $GOT" >&2; exit 1; }
unzip -q "$TMP/nemo.zip" -d "$TMP/x"
[ -d "$TMP/x/NemoTextProcessing.xcframework" ] || { echo "✗ zip lacks NemoTextProcessing.xcframework" >&2; exit 1; }
mv "$TMP/x/NemoTextProcessing.xcframework" "$DEST/"
