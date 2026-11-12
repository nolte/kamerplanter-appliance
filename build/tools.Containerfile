# Tool container for the proof of concept: builds the system image, turns it
# into a disk image and boots that in QEMU. Runs privileged with /dev/kvm.
FROM quay.io/fedora/fedora:44@sha256:102f5031dc46ed1975bd2cd98bdf19c59617f3f0026310022f3cb680abe056d3

RUN dnf -y install \
        podman skopeo image-builder \
        qemu-system-x86-core qemu-img edk2-ovmf seabios-bin seavgabios-bin \
        openssh-clients curl jq xz procps-ng \
    && dnf clean all

WORKDIR /work
