#!/usr/bin/env bash
# Packages the raw disk image for distribution: compressed, named by version
# and architecture, with a checksum file. Fails when an artifact is at or above
# the size limit of a GitHub release asset (spec/release-distribution/ §B8).
set -euo pipefail

version=${1:?usage: build/package.sh <version>}
name="kamerplanter-appliance-${version}-$(uname -m)"
dist=.build/dist
limit=$((2 * 1024 * 1024 * 1024))

[ -f .build/disk.raw ] || { echo ".build/disk.raw not found; run the disk build first" >&2; exit 1; }
rm -rf "$dist"
mkdir -p "$dist"

xz -T0 -6 -c .build/disk.raw >"$dist/$name.raw.xz"
(cd "$dist" && sha256sum -- *.raw.xz >SHA256SUMS)

for file in "$dist"/*.raw.xz; do
    size=$(stat -c %s "$file")
    if [ "$size" -ge "$limit" ]; then
        echo "$file is $size bytes, at or above the 2 GiB limit of a release asset" >&2
        exit 1
    fi
done

ls -l "$dist"
cat "$dist/SHA256SUMS"
