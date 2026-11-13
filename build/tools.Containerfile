# Tool container for the proof of concept: builds the system image, turns it
# into a disk image and boots that in QEMU. Runs privileged with /dev/kvm.
FROM quay.io/fedora/fedora:46@sha256:02031526999d46c9f9c6490eeccf4cafd735438b9d0fb5e1d9fc941d7886e2ff

RUN dnf -y install \
        podman skopeo image-builder \
        qemu-system-x86-core qemu-img edk2-ovmf seabios-bin seavgabios-bin \
        openssh-clients curl jq xz procps-ng \
    && dnf clean all

WORKDIR /work
