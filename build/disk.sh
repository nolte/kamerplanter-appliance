#!/usr/bin/env bash
# Builds the raw disk image from the system image in local container storage.
# Runs inside the tool container (see build/in-tools.sh).
set -euo pipefail

ref=${1:?usage: build/disk.sh <image-ref>}
out=.build/disk

rm -rf "$out"
image-builder build raw \
    --bootc-ref "$ref" \
    --bootc-default-fs ext4 \
    --output-dir "$out" \
    --output-name disk \
    --progress verbose

raw=$(find "$out" -name '*.raw' | head -n1)
[ -n "$raw" ] || { echo "no raw image in $out" >&2; ls -lR "$out" >&2; exit 1; }
mv "$raw" .build/disk.raw
ls -lh .build/disk.raw
