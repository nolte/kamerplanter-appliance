---
title: Getting Started
audience: [maintainer]
content_mode: tutorial
track: developer-docs
last_updated: 2026-11-13
---

# Getting Started

This walks through building the proof of concept and booting it in a local virtual machine.

## Prerequisites

- Docker, with your user allowed to run containers
- Access to `/dev/kvm`
- [Task](https://taskfile.dev)
- About 20 GB of free disk space and 6 GB of free memory

Every build and test step runs inside a privileged tool container that brings podman, the bootc tooling and QEMU, so nothing beyond the list above is installed on your machine.

## Build and boot

```bash
task tools:build   # tool container: podman, image-builder, QEMU
task image:build   # system image of the appliance
task disk:build    # raw disk image from the system image
task test:boot     # boot the disk image under the firmware and device matrix
task disk:package  # compressed disk image and checksums in .build/dist/
```

`task test:boot` prints one line per run and keeps the serial console and a diagnosis of every failed run under `.build/boot/`. The first boot of each run pulls the container images from their registries and takes several minutes.

## Clean up

```bash
task clean
```
