#!/usr/bin/env bash
# Runs a command inside the tool container. The container is privileged
# because nested podman, loop devices and KVM need it.
set -euo pipefail
cd "$(dirname "$0")/.."
exec docker run --rm --privileged \
    --device /dev/kvm \
    -v kamerplanter-appliance-containers:/var/lib/containers \
    -v kamerplanter-appliance-osbuild:/var/cache/image-builder \
    -v "$PWD":/work -w /work \
    "${TOOLS_IMAGE:-kamerplanter-appliance-tools:poc}" "$@"
