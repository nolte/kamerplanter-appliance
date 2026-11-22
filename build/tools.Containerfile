# Tool container for the proof of concept: builds the system image, turns it
# into a disk image and boots that in QEMU, with NoCloud drives and a seed URL
# server for the provisioning tests. Runs privileged with /dev/kvm.
FROM quay.io/fedora/fedora:46@sha256:65f229c50e5a6ec4b4468da58835c1a30db77fe835914ffa2086a05a79db0e24

RUN dnf -y install \
        podman skopeo image-builder \
        qemu-system-x86-core qemu-img edk2-ovmf seabios-bin seavgabios-bin \
        openssh-clients curl jq xz procps-ng \
        dosfstools mtools python3 \
    && dnf clean all

WORKDIR /work
