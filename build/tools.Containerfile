# Tool container for the proof of concept: builds the system image, turns it
# into a disk image and boots that in QEMU. Runs privileged with /dev/kvm.
FROM quay.io/fedora/fedora:44@sha256:1da752148b03fd36679caa7d4ba2d7bbc638602539dad43f975d979e63429be6

RUN dnf -y install \
        podman skopeo image-builder \
        qemu-system-x86-core qemu-img edk2-ovmf seabios-bin seavgabios-bin \
        openssh-clients curl jq xz procps-ng \
    && dnf clean all

WORKDIR /work
