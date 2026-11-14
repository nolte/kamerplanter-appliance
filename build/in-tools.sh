#!/usr/bin/env bash
# Runs a command inside the tool container. The container is privileged
# because nested podman, loop devices and KVM need it; the host's /dev is
# passed through so that a free loop device is visible. /var/tmp is a volume
# (removed with the container): podman lays an overlay over the build context
# there, and an overlay cannot sit on the container's own overlay file system.
set -euo pipefail
cd "$(dirname "$0")/.."
exec docker run --rm --privileged \
    --device /dev/kvm \
    -e DISK_SIZE -e DISK -e DISK_OUT -e IMAGE_REF \
    -v /dev:/dev \
    -v kamerplanter-appliance-containers:/var/lib/containers \
    -v /var/tmp \
    -v "$PWD":/work -w /work \
    "${TOOLS_IMAGE:-kamerplanter-appliance-tools:poc}" "$@"
