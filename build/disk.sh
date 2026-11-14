#!/usr/bin/env bash
# Builds the raw disk image from a system image in local container storage.
# Runs inside the tool container (see build/in-tools.sh) or on a CI runner.
#
#   build/disk.sh <image-ref> [<target-imgref>]
#
# <target-imgref> is the registry reference the installed appliance updates
# from (spec/update-and-rollback/ A2); it defaults to the release channel.
#
# The image is written with `bootc install to-disk`. `image-builder` is the
# intended tool, but its build sandbox (bwrap) is denied by the AppArmor
# profile that Ubuntu attaches to bwrap, also inside a privileged container.
set -euo pipefail

ref=${1:?usage: build/disk.sh <image-ref> [<target-imgref>]}
target=${2:-ghcr.io/nolte/kamerplanter-appliance:stable}
size=${DISK_SIZE:-10G}
out=${DISK_OUT:-.build/disk.raw}

# The container images are bound to the system image, and `bootc install`
# puts them into the disk. It pulls them from their registries
# (--bound-images pull): copying them from this host's storage fails, because
# the units pin the digests of multi-architecture indexes while the storage
# holds only the manifest of this architecture.

# A system image from a registry is installed from the registry itself: a
# copy out of local storage is recompressed, and the installed appliance
# would then report another digest than the registry and take the same
# content for an update. The install container uses this host's registry
# configuration and credentials to fetch it.
source_args=()
run_args=()
case $ref in
    localhost/*) ;;
    *)
        source_args=(--source-imgref "docker://$ref")
        run_args=(--network host -v /etc/containers/registries.conf.d:/etc/containers/registries.conf.d:ro
                  -v /etc/hosts:/etc/hosts:ro)
        for auth in "${REGISTRY_AUTH_FILE-}" /run/containers/0/auth.json; do
            if [ -n "$auth" ] && [ -f "$auth" ]; then
                run_args+=(-v "$auth:/run/containers/0/auth.json:ro")
                break
            fi
        done
        ;;
esac

mkdir -p "$(dirname "$out")" /run/udev
rm -f "$out"
truncate -s "$size" "$out"

podman run --rm --privileged --pid=host \
    --security-opt label=type:unconfined_t \
    -v /dev:/dev \
    -v /run/udev:/run/udev \
    -v /var/lib/containers:/var/lib/containers \
    -v "$(realpath "$(dirname "$out")")":/output \
    "${run_args[@]}" \
    "$ref" \
    bootc install to-disk --generic-image --via-loopback --filesystem ext4 --wipe \
        "${source_args[@]}" --target-imgref "$target" --bound-images pull \
        "/output/$(basename "$out")"

ls -lhs "$out"
