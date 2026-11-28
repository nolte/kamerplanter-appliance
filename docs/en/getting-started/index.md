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

The VM tests (`task test:boot`, `task test:update`, `task test:data-disk`) also run on GitHub Actions, in parallel jobs, through the workflow `vm-tests`: on a pull request once it carries the label `vm-tests` (and again on every push that finds the label set), after each merge to `develop` that changes `image/`, `build/` or `tests/boot/`, and by hand under **Actions → vm-tests → Run workflow**. The job summary lists every result; the results files and serial consoles are attached to the run.

The label is the consent to running the pull request's own test scripts (a maintainer sets it; Renovate sets it on its own base image updates), and it covers the commit it was set on. A label that is set less than 5 minutes after someone else pushed that commit, or after the pull request was reopened, is removed again, with a failing `vm-gate` that says so: the page it was set from may still have shown the commit before. This also holds when the label lands a moment after the push, while GitHub is still processing the push. The VM tests that the label started end in their first job and test nothing. Look at the head again and set the label once more; it counts from 5 minutes after the push. Whoever pushed the commit to a branch of this repository themselves (Renovate on its own pull requests, or `gh pr create --label vm-tests` right after the push) can set the label at once. A push that changes `.github/workflows/vm-tests.yml`, `build/`, `tests/boot/` or `tests/image/`, and every push to a pull request from a fork, removes the label: the required status `vm-gate` then fails until a maintainer has looked at the new commit and sets the label again. The run that such a push started ends in its first job, `consent`, and tests nothing: before anything is built, that job asks GitHub whether the pull request still has the label and whether `vm-gate` has accepted the commit. Setting the label again starts the VM tests of that commit, and only their result counts. If `vm-gate` does not accept the commit within 10 minutes, `consent` fails and the tests do not run: read what `vm-gate` says, then remove the label and set it again. `consent` also fails, and nothing is built, when someone runs an old run again whose commit is not the head of the pull request any more. A run that is started again on a pull request that is closed or merged ends in `consent` as well and tests nothing. The test jobs ask for the label once more when they start, after the build: if the label was removed in the meantime, they fail at once with the note "No test result", which says nothing about the image. A test job that has already started runs to its end. A push that changes only other paths keeps the label, unless `vm-gate` never accepted the commit before it (two pushes in quick succession) or cannot read from GitHub when the push arrived and when the label was set; `vm-gate` then says that the time could not be read, and the label is set again by hand once the commit is 5 minutes old, also on a pull request of Renovate. Reopening a pull request keeps the label as well. A head that was pushed while the pull request was closed has no test result, though: `vm-gate` fails on it until someone removes the label and sets it again, and a further push before that removes the label.

## Running the appliance

- [Updates and rollback](updates.md) — how the appliance updates itself and returns to the previous release
- [Data disk and backup disk](data-disk.md) — keep the data and the pre-update backups on separate local disks

## Clean up

```bash
task clean
```
