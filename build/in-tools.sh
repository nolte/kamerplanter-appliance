#!/usr/bin/env bash
# Runs a command inside the tool container. The container is privileged
# because nested podman and loop devices need it; the host's /dev is
# passed through so that a free loop device is visible. /dev/kvm is passed
# through when the host has it: only the boot tests (tests/boot/) need it,
# the image and disk builds and the checks run without it. /var/tmp is a volume
# (removed with the container): podman lays an overlay over the build context
# there, and an overlay cannot sit on the container's own overlay file system.
set -euo pipefail
cd "$(dirname "$0")/.."
kvm=()
[ -e /dev/kvm ] && kvm=(--device /dev/kvm)
exec docker run --rm --privileged \
    "${kvm[@]}" \
    -e DISK_SIZE -e DISK -e DISK_OUT -e IMAGE_REF \
    -e FIRST_BOOT_TIMEOUT -e REBOOT_TIMEOUT -e HEALTH_MINUTES \
    -v /dev:/dev \
    -v kamerplanter-appliance-containers:/var/lib/containers \
    -v /var/tmp \
    -v "$PWD":/work -w /work \
    "${TOOLS_IMAGE:-kamerplanter-appliance-tools:poc}" "$@"
