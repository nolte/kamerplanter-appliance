# Tool container for the proof of concept: builds the system image, turns it
# into a disk image and boots that in QEMU, with NoCloud drives and a seed URL
# server for the provisioning tests. Runs privileged with /dev/kvm.
FROM quay.io/fedora/fedora:46@sha256:fe07221648d8016255ff68e4c59b138d988ab3517a4ae552e799b2fb47e98175

RUN dnf -y install \
        podman skopeo image-builder \
        qemu-system-x86-core qemu-img edk2-ovmf seabios-bin seavgabios-bin \
        openssh-clients curl jq xz procps-ng \
        dosfstools mtools python3 \
    && dnf clean all

WORKDIR /work
