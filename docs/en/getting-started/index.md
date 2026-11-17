---
title: Getting Started
audience: [maintainer]
content_mode: tutorial
track: developer-docs
last_updated: 2026-11-17
---

# Getting Started

This walks through building the proof of concept and booting it in a local virtual machine.

## Prerequisites

- Docker, with your user allowed to run containers
- Access to `/dev/kvm`, for the boot tests (`task test:boot`) only
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

The VM tests (`task test:boot`, `task test:update`, `task test:data-disk`) also run on GitHub Actions, in parallel jobs, through the workflow `vm-tests`: on a pull request once it carries the label `vm-tests` (and again on every push to it), after each merge to `develop` that changes `image/`, `build/` or `tests/boot/`, and by hand under **Actions → vm-tests → Run workflow**. The job summary lists every result; the results files and serial consoles are attached to the run.

## Running the appliance

- [Updates and rollback](updates.md) — how the appliance updates itself and returns to the previous release
- [Data disk and backup disk](data-disk.md) — keep the data and the pre-update backups on separate local disks

## Clean up

```bash
task clean
```
