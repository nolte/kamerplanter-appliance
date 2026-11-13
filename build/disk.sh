#!/usr/bin/env bash
# Builds the raw disk image from the system image in local container storage.
# Runs inside the tool container (see build/in-tools.sh).
#
# The image is written with `bootc install to-disk`. `image-builder` is the
# intended tool, but its build sandbox (bwrap) is denied by the AppArmor
# profile that Ubuntu attaches to bwrap, also inside a privileged container.
set -euo pipefail

ref=${1:?usage: build/disk.sh <image-ref>}
size=${DISK_SIZE:-10G}
out=.build/disk.raw

mkdir -p .build /run/udev
rm -f "$out"
truncate -s "$size" "$out"

podman run --rm --privileged --pid=host \
    --security-opt label=type:unconfined_t \
    -v /dev:/dev \
    -v /run/udev:/run/udev \
    -v /var/lib/containers:/var/lib/containers \
    -v "$PWD/.build":/output \
    "$ref" \
    bootc install to-disk --generic-image --via-loopback --filesystem ext4 --wipe /output/disk.raw

ls -lhs "$out"
