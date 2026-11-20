# Tool container for the proof of concept: builds the system image, turns it
# into a disk image and boots that in QEMU, with NoCloud drives and a seed URL
# server for the provisioning tests. Runs privileged with /dev/kvm.
FROM quay.io/fedora/fedora:46@sha256:5548780ef134010b6484d101d30430a0d1e9e95d956a29371ec8055b3e6e9a2b

RUN dnf -y install \
        podman skopeo image-builder \
        qemu-system-x86-core qemu-img edk2-ovmf seabios-bin seavgabios-bin \
        openssh-clients curl jq xz procps-ng \
        dosfstools mtools python3 \
    && dnf clean all

WORKDIR /work
