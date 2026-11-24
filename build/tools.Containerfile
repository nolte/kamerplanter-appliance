# Tool container for the proof of concept: builds the system image, turns it
# into a disk image and boots that in QEMU, with NoCloud drives and a seed URL
# server for the provisioning tests. Runs privileged with /dev/kvm.
# Fedora removes superseded digests of quay.io/fedora/fedora:46 within about a
# day, so the base comes from the project's mirror of it
# (.github/workflows/base-image-mirror.yml), which keeps every digest it has
# seen; the digest is the upstream one (#48).
FROM ghcr.io/nolte/kamerplanter-appliance-tools-base:46@sha256:301c729f479016f2cddd1e62b7e809cdf6ecd42c6c6e7ba2a85d82ead4a9671f

RUN dnf -y install \
        podman skopeo image-builder \
        qemu-system-x86-core qemu-img edk2-ovmf seabios-bin seavgabios-bin \
        openssh-clients curl jq xz procps-ng \
        dosfstools mtools python3 \
    && dnf clean all

WORKDIR /work
