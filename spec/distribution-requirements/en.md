# Distribution Requirements

Status: draft

## Context

The Kamerplanter appliance is delivered as a bootable image that installs an operating system and runs the Kamerplanter containers on it (see the repository `README.md`). The operating system underneath is a means, not a product: the user should neither notice it nor maintain it. This spec states what a base distribution has to provide for that to hold. It names no distribution, so that every candidate is evaluated against the same list and the eventual choice can be justified requirement by requirement.

The requirements derive from the project goals in `README.md` and from the upstream release Compose file. Established by reading `docker-compose.release.yml` in a working copy of `nolte/kamerplanter` on 2026-11-12: the web UI is published on port 8080 and the API on port 8000, both bound to `${KAMERPLANTER_BIND_ADDRESS:-127.0.0.1}` (lines 153 and 242); the published database and Ollama ports bind to `127.0.0.1` (lines 29, 62, 83, 103) [R1].

Established on 2026-11-12 by a review of the candidates' own documentation, package manifests, kernel configurations, and release artifacts through research agents; nothing was installed, booted, or measured:

| Point | `bootc` on Fedora or CentOS Stream [R2][R3][R4][R5][R6] | Flatcar Container Linux [R7][R8] | openSUSE MicroOS, Leap Micro [R9][R10][R11] |
|-------|------------------|-------------------------|------------------------------|
| One versioned image (A2) | Yes, an OCI image with a digest | Yes, a versioned `/usr` image | No, package-based without an image identifier |
| Automatic atomic update (B1, B2) | Yes; the reboot window needs a timer override | Yes, with reboot windows | Yes, with reboot windows |
| Rollback on an own health check (B3) | Through greenboot, an additional package that the bootc documentation does not cover | Documented recipe of several units | Native plugin directory of health-checker |
| Containers, configuration, and baseline arrive with the system update (B7, B9, K3) | Yes, they are part of the image | No, the system updates itself only; the rest is to be built | Only through an own package repository |
| Restart on exit and on unhealthy, ordering, orderly stop (C11, C12, C13) | Native with Podman and systemd | Restart on exit native; unhealthy needs an own watchdog | Native with Podman and systemd |
| Upstream Compose file used directly (C8) | No; translation to systemd units | Only through a community extension not tested by Flatcar | Through additional packages, without the systemd supervision |
| Same content on every target (deployment-targets H10) | Yes, with cloud-init added to the image | Identical system, one small variant per target | Only with an own image profile |
| Installer ISO (D1, D2) | Possible; the tooling is in transition | The official ISO is a BIOS-only live system; an own installer is needed | Unattended self-install ISO from the same build as the raw image |
| Legacy BIOS and UEFI (deployment-targets H4) | Hybrid partition layout, not stated as supported | Both boot loaders in the same image | MicroOS only in its GRUB2 variant; SUSE documents Micro 6.2 as UEFI only |
| Devices that Proxmox VE assigns by default (deployment-targets H3) | Fedora builds both drivers; CentOS Stream does not build the LSI driver | Both drivers are in the initrd of the release | Not documented |
| Mandatory access control enforcing (G5) | Yes | No, permissive by default, with limits for shared volumes | Yes |
| Firewall with default deny (G1) | To be added | To be added | To be added in MicroOS |
| Support lifecycle (I1) | Fedora about 13 months per release; CentOS Stream 10 until 2030-05-31 | A stable channel without fixed end dates, an LTS channel of 18 months | MicroOS rolling; the status of Leap Micro is unclear |

Established on 2026-11-13 from the upstream documentation (`docs/de/deployment/konfigurationsmatrix.md`, `docs/de/reference/environment-variables.md`, `docs/de/deployment/backup-restore.md` in a working copy of `nolte/kamerplanter`) and from the first prototype runs: with `DEBUG=false` the backend refuses to start without `JWT_SECRET_KEY`, `ARANGODB_PASSWORD`, `FERNET_KEY`, `ERASURE_TOMBSTONE_SALT`, and `LOG_PSEUDONYM_SALT`, while the upstream `.env.example` names only the database password and the two salts, and the release Compose file passes neither `JWT_SECRET_KEY` nor `FERNET_KEY`. The upstream documentation states that `ERASURE_TOMBSTONE_SALT` must never change and that data encrypted with `FERNET_KEY` and deletion records depend on these values after a restore. A probe with the pinned ArangoDB image showed that it takes `ARANGO_ROOT_PASSWORD` only when the database is first created: after a restart with another value, the old password still logs in and the new one is refused.

Established on 2026-11-14 by a feasibility spike for an optional data disk (a VM booted from the prototype's disk image with a second disk attached, on a GitHub-hosted runner with KVM): bind mounts from the data disk onto `/etc/kamerplanter`, `/var/lib/kamerplanter/pinned`, and the two database volume directories keep working across a new deployment that runs the ostree `/etc` merge and across a rollback; content written after the move stays on the data disk and is not copied into the `/etc` of any deployment on the system disk; a fresh appliance given the same disk uses its secrets and data unchanged. ext4 file system labels hold at most 16 characters [R12] and xfs labels 12 [R13], which the spike confirmed when `mkfs.ext4` truncated `kamerplanter-data`; the labels are therefore `kp-data` and `kp-backup`. The spike ran as workflow `spike-data-disk`, run 43605692183. It did not cover LUKS2 or the TPM, the move of a running appliance, or a USB stick. The base image ships `mkfs.ext4`, `cryptsetup`, `systemd-cryptenroll`, and the TPM2 tools.

Unestablished: everything the acceptance criteria demand of a prototype, in particular boot and rollback under legacy BIOS, the drivers actually present in the initial RAM disk, behaviour on power loss, and the footprint. For openSUSE, the licence, trademark, and lifetime pages could not be fetched, and parts of the MicroOS findings come from a third-party mirror of its image description.

Boundaries: application behaviour belongs to `nolte/kamerplanter`. Where the appliance runs, and what differs between those places, is owned by `spec/deployment-targets/`. The build pipeline, the update channel and release process, and the first-boot setup interface are subjects of their own specs, which do not exist yet. This spec states only what the distribution has to make possible for them.

Readers: maintainers who select the base distribution and build the appliance, and reviewers who evaluate a candidate.

## Goals

- A candidate distribution can be accepted or rejected against a fixed, testable list.
- Operating the appliance requires no system administration: the user never patches, manages operating-system users, hardens, or repairs the operating system by hand.
- Updates are as simple as possible: they happen by themselves, and a failed update undoes itself.
- The system contains nothing that running the containers does not need: no graphical system, no desktop, no development tools.

## Non-Goals

- Selecting the distribution. The choice is an open question this spec prepares.
- Specifying the build pipeline, the release process, or the setup interface.
- Requirements on the Kamerplanter services themselves.
- Multi-node operation, clustering, or high availability.
- Hardware support beyond the reference targets named in `spec/deployment-targets/`.
- A network file system as data location (E15).

## Requirements

### A. Immutable system image

- **A1 MUST** mount the operating system tree (kernel, userland, container runtime) read-only during normal operation.
- **A2 MUST** deliver and identify the system as one versioned image, so that two installations of the same version have identical system content.
- **A3 MUST** keep the appliance patched and running without the user ever invoking a package manager.
- **A4 MUST** confine local configuration to a declared set of writable locations.
- **A5 SHOULD** verify the integrity of the system image at boot or at activation of an update.

### B. Updates

- **B1 MUST** update the operating system and the Kamerplanter containers without user action: no command, no login, and no decision.
- **B2 MUST** apply updates atomically: an update either activates completely or leaves the running version untouched, including when power is lost at any point.
- **B3 MUST** return to the previous version automatically when the new version fails to boot or fails a health check that the appliance declares.
- **B4 MUST** keep at least the previously running version installed and bootable.
- **B5 MUST** let the appliance control when the activating reboot happens.
- **B6 MUST** verify the cryptographic authenticity of an update before activating it.
- **B7 MUST** never require the user to match operating-system and container versions: every combination that the update mechanism can produce either works or is rolled back.
- **B8 SHOULD** use the update mechanism that the distribution provides and maintains, with as few components as possible that this project has to build or operate itself.
- **B9 SHOULD** carry the operating system and the container images in one update, so that only combinations released together ever run.
- **B10 SHOULD** accept updates from a source that this project controls, so that a faulty update can be withheld.
- **B11 SHOULD** transfer only the changed parts of an image rather than the full image.
- **B12 MAY** offer a manual update trigger and a manual rollback on the console.

### C. Container workload

- **C1 MUST** include an OCI container runtime in the system image, maintained by the distribution.
- **C2 MUST** run the published upstream container images unmodified.
- **C3 MAY** load the container images from a registry at the first start instead of carrying them in the delivered artifact.
- **C4 MUST** reference every container image by digest.
- **C5 MUST** control the containers with the means of the distribution itself, its service manager and its container runtime, without an additional orchestrator.
- **C6 MUST NOT** require Kubernetes or any other cluster control plane.
- **C7 MUST** generate and verify any translation of the upstream Compose definition in the build, if the runtime cannot consume that definition directly.
- **C8 SHOULD** consume the upstream Compose definition without translation.
- **C9 MUST** allow the optional services (`vectordb`, `ollama`, `timescaledb`) to be enabled after installation without modifying the system image.
- **C10 MUST** start the containers on every later boot from the images already loaded, without access to a registry.
- **C11 MUST** restart a container automatically when it exits or is reported unhealthy.
- **C12 MUST** bring all containers up in the required order after every reboot of the machine, planned or unplanned, without user action.
- **C13 MUST** stop the containers in order on shutdown, so that the databases close cleanly.

### D. Installation and first boot

- **D1 MUST** install from a bootable ISO onto the disk of a VM or of an x86_64 mini PC.
- **D2 MUST** complete the installation with no more user input than confirming the target disk.
- **D3 SHOULD** support a fully unattended installation driven by a supplied configuration.
- **D4 MUST** accept machine-readable provisioning data at first boot for hostname, network, and an administrator SSH key.
- **D5 MUST** provide a hook that runs a one-shot step at first boot before the containers start.
- **D6 MUST NOT** ship preset credentials for any operating-system account or any service.
- **D7 MUST** configure the network through DHCP by default and allow a static configuration.
- **D8 MUST** be deliverable as a pre-installed image that boots directly from the medium it was written to, for targets without an installer step.
- **D9 MUST** generate every secret that the Kamerplanter services require, individually per installation, and keep it across updates and rollbacks.
- **D10 MUST** generate a secret that a later release newly requires at the first boot of that release, without user action.
- **D11 MUST** let the user override every generated secret and every setting of the services, before or after the first start, in one documented file that survives updates and rollbacks.
- **D12 MUST** check the effective configuration before the services start and keep them stopped with a message that names the faulty value, when a value is invalid, or when a value that must stay constant once a service has started with it has changed or is missing.

### E. State and data

- **E1 MUST** keep all persistent state in a location separate from the system image, untouched by updates and rollbacks.
- **E2 MUST** make the set of persistent locations enumerable, so that everything outside it can be discarded and reproduced. With a data disk (E6), the locations on it belong to that set.
- **E3 MUST** let the data location grow to the available space, at first boot and after a virtual disk is enlarged, without reinstalling.
- **E4 SHOULD** support consistent backups through hypervisor snapshots on virtualised targets, including a filesystem freeze through a guest agent.
- **E5 MUST** keep the generated secrets in the persistent state, on the data disk of E6 when one is set up and on the system disk otherwise, and name them in the backup guidance, since data restored without them loses its encrypted fields and deletion records.
- **E6 MAY** keep the persistent state of E9 on an optional, separate local data disk: a second virtual disk, a second internal drive, a USB disk, or a USB stick. E7 to E16 apply only when a data disk or a backup disk is set up; without one, the persistent state stays on the system disk as before.
- **E7 MUST** format a disk as data disk (ext4, label `kp-data`) or as backup disk (ext4, label `kp-backup`, see `spec/update-and-rollback/` D8) only when it is named explicitly by a `/dev/disk/by-id/` or `/dev/disk/by-uuid/` path, from the system side only: as the system credential of the same name, or as a setting kept on the system disk. The user file of D11 MAY name a disk only while no data disk is set up; while one is, the user file lies on that disk, and its naming and forcing settings MUST be ignored with a message that says where to set them instead. It MUST refuse a named disk that carries another file system or partition table, naming the signature found, unless the naming explicitly forces the format; a forced format applies once to the named device, whatever path names it, and is never repeated for a device that already carries `kp-data` or `kp-backup`. It MUST NOT format the disk that holds the running system, any of its partitions, or a mounted device, even when forced.
- **E8 MUST**, when a data disk or a backup disk is set up or adopted, record on the system disk that it is set up and the UUID of its file system or LUKS2 container. It MUST find a set-up disk by its label, never by its device name, accept it only under the recorded UUID, and mount it before any service that reads the configuration or the data starts. When more than one device carries the label, or a device carries the label under another UUID, it MUST keep the services stopped with the devices named and MUST NOT mount or read such a device.
- **E9 MUST** mount the data disk and the backup disk with `nosuid`, `nodev`, and `noexec` after a file system check, and keep on the data disk the database volumes, the user file, the generated secrets, and the records of the values that must stay constant (D12). Each time it mounts a disk it MUST enforce owner root, or the service account that needs a location, and modes no wider than 0700 for directories and 0600 for the secrets, the user file, and the records, and MUST refuse a disk on which one of these locations is a symbolic link, a hard link to a file outside it, or a device or other special file. It MUST refuse a data disk or backup disk on which the directory of the pre-update backups (`spec/update-and-rollback/` D8), an entry in it, or the release marker of E13 is a symbolic link or of another type, and MUST NOT follow a symbolic link on such a disk when it writes or deletes there. The update state of `spec/update-and-rollback/` stays on the system disk.
- **E10 MUST**, when a freshly installed appliance is given a data disk named as in E7, use the configuration, secrets, and data on it, record its identity as in E8, and generate only the secrets the disk does not hold yet (D10). It MUST NOT adopt an unnamed disk only because it carries the label `kp-data`.
- **E11 MUST**, when a data disk is named on an appliance that holds data on its system disk, stop the services, move the data, configuration, secrets, and records of E9 onto the disk, and continue from it. It MUST keep the copy on the system disk until the services have passed the health check of `spec/update-and-rollback/` E1 from the data disk and the keeping period of D4 there has passed, and then delete every copy of the moved state on the system disk, including the copies in the configuration of every installed deployment, and record the deletion. When the services fail that health check from the data disk, it MUST return to the copy on the system disk, record the data disk as not set up, and not mount it again until it is named anew. A missing data disk is no failed start; E12 applies to it.
- **E12 MUST** keep the services stopped and report that the disk `kp-data` is missing when a data disk is set up but absent, cannot be unlocked, or is present only unencrypted although it was set up encrypted. In that state it MUST NOT generate any secret and MUST NOT format, encrypt, or overwrite a disk, and its message MUST NOT contain a key.
- **E13 MUST** record on the data disk the highest release whose services have passed the health check of `spec/update-and-rollback/` E1 on it, and keep the services stopped with both releases named when the running release is older; a development build counts as older than any release. The record is part of the backup of `spec/update-and-rollback/` D2, so that a rollback restores it with the data. One documented command MAY override the refusal deliberately; it MUST require root on the console or through administrative access, MUST NOT be reachable through the web UI, the API, the provisioning data, or any file on the data disk, MUST apply only to the pair of releases it names, and MUST be recorded with time and both releases in the update state.
- **E14 MAY** encrypt the data disk and the backup disk with LUKS2. Encryption MUST be set up when the disk is formatted, before anything is written to it; a key supplied for a disk already set up unencrypted MUST be refused with a message. The key MUST come from the provisioner, as a system credential or in a dedicated file on the system disk outside the user file of D11, and MUST NOT be generated by the appliance; a key shorter than 32 bytes MUST be refused. The appliance MUST keep it outside the configuration locations that are merged per deployment, owned by root with mode 0600 in a directory of mode 0700, or sealed in the TPM to a stated PCR policy that covers the boot chain; MUST NOT write it to the data disk, the journal, the update record, the console, or the output of any command, nor pass it on a command line; MUST refuse a key passed on the kernel command line, which every user can read; MUST delete it from any provisioning data it keeps once stored, encrypted credential stores included; and MUST delete the stored key when the disk it unlocks is no longer set up. After unlocking, it MUST verify that the container encrypts its data with the cipher and key size recorded when it was set up, and MUST refuse a container that does not, such as one whose data segment uses `cipher_null`, as a disk of another identity under E8.
- **E15 MUST NOT** use a network file system as data location.
- **E16 MUST**, when the data disk is encrypted, accept a backup disk only when it is encrypted under E14 as well.

### F. Footprint

- **F1 MUST** contain only the components needed to boot, update, run containers, and be diagnosed.
- **F2 MUST NOT** contain a graphical system such as X11 or Wayland, a desktop environment, or graphical applications.
- **F3 MUST NOT** contain compilers or development toolchains.
- **F4 MUST NOT** run a service that the appliance does not use.
- **F5 MUST** list the installed components for every release, so that F1 to F4 can be checked.
- **F6 MUST** have its idle memory use, installed size, and boot time measured and recorded for every evaluated candidate.
- **F7 SHOULD** be the candidate with the smaller footprint when candidates are otherwise equal.

### G. Network and security

- **G1 MUST** deny inbound connections by default and open only the web UI (8080), the API (8000), and explicitly enabled administrative access.
- **G2 MUST** keep database and broker ports unreachable from outside the VM.
- **G3 MUST** keep remote administrative access disabled until the user supplies a key, and never permit password login.
- **G4 MUST** synchronise the system clock.
- **G5 SHOULD** confine containers with an enforcing mandatory access control system.
- **G6 MUST** receive security fixes for kernel, base system, and container runtime from a distribution with a public advisory process.
- **G7 MUST** be able to serve the web UI and the API over TLS, as `spec/deployment-targets/` §F requires for hosted VMs.
- **G8 MUST** block a source address automatically after repeated failed logins at the web UI, the API, or the administrative access, by a mechanism such as fail2ban.
- **G9 MUST** limit the rate of new connections and requests per source address, so that a flood from few sources does not make the appliance unreachable for others.
- **G10 MUST** lift an automatic block after a limited time without user action.
- **G11 MUST** ship the protections of G8 and G9 enabled and preconfigured, as part of the security baseline of §K.
- **G12 SHOULD** let the user exempt own addresses from blocking and change the thresholds.

### H. Target platforms and artifacts

- **H1 MUST** run on every reference target named in `spec/deployment-targets/`: as a KVM guest with virtio storage and network devices, and on x86_64 mini PCs.
- **H2 MUST** boot under the firmware that each reference target offers by default.
- **H3 MUST** produce all delivery artifacts of an architecture from the same source definition with identical system content.
- **H4 MUST** build in CI without interactive steps and with pinned inputs.
- **H5 SHOULD** build reproducibly: the same inputs yield the same system content.
- **H6 SHOULD** include a QEMU guest agent on virtualised targets.
- **H7 MAY** support aarch64.
- **H8 SHOULD** provide the drivers and boot modes that the planned targets in `spec/deployment-targets/` require, so that connecting them needs no change of base distribution.

### I. Sustainability of the base

- **I1 MUST** be actively maintained with a documented support lifecycle.
- **I2 MUST** permit redistribution of the built image free of charge and without a subscription.
- **I3 MUST** be buildable with freely available tooling.
- **I4 SHOULD** deliver major-version upgrades of the base through the same update mechanism, without reinstalling.

### J. Operability

- **J1 MUST** make system and container logs available in one place with bounded disk use.
- **J2 MUST** expose the running version and the update state in machine-readable form.
- **J3 SHOULD** allow the console to show the appliance version and the address of the web UI after boot.

### K. Operating overhead

- **K1 MUST** require no operating-system user account to be created or maintained by the user.
- **K2 MUST** ship its security baseline as part of the system image, so that the user applies no hardening.
- **K3 MUST** deliver changes to the baseline through the update mechanism of §B and through no other channel.
- **K4 MUST** carry out recurring maintenance, such as log rotation, removal of superseded images, and clock synchronisation, without user action.
- **K5 SHOULD** make the baseline verifiable by an automated check that runs in the build.

## Acceptance Criteria

Each criterion is checked on a prototype of the candidate. The criteria roll several requirements together; every requirement stays normative on its own.

- [ ] A write to a system path fails on the installed appliance (A1).
- [ ] Two installations of the same version report the same system image identifier (A2).
- [ ] An update interrupted by power loss during staging, and one interrupted during activation, each boot into a consistent version (B2).
- [ ] An update to a version with a deliberately failing health check ends on the previous version without user action and with the data intact (B3, B4, E1).
- [ ] An update of the operating system and of the containers completes without a command, a login, or a decision by the user, and its reboot happens at the time the appliance configured (B1, B5).
- [ ] An update with an invalid signature is refused (B6).
- [ ] After every update and every rollback, the running combination of operating-system and container versions passes the health check without the user having chosen either version, and every running container is referenced by digest (B7, C4).
- [ ] The components that this project builds or operates for updating are listed, and each is justified against the mechanism the distribution provides (B8).
- [ ] Installation and first start on a VM with internet access end with all core containers healthy, and a reboot of that VM without network access ends the same way (C2, C10, D1).
- [ ] A killed core container and one reported unhealthy are each restarted without user action, by the service manager of the distribution, and no Kubernetes component is present (C5, C6, C11).
- [ ] After a planned reboot and after a hard reset of the machine, all core containers become healthy in the required order and the web UI answers, without user action and without data loss (C12, C13).
- [ ] An optional service is enabled on an installed appliance while the system image identifier stays unchanged (C9).
- [ ] An ISO installation on Proxmox VE needs no input beyond the target disk and ends with the web UI answering on port 8080 (D1, D2, D7, H1, H2).
- [ ] A Hetzner Cloud server created from an appliance artifact ends with the web UI answering on port 8080 (H1, H2, H3).
- [ ] The ISO written to a USB medium installs an x86_64 mini PC, and the web UI answers on port 8080 (D1, H1, H2).
- [ ] The pre-installed image, written to the disk of a VM, boots directly, and all core containers become healthy (D8).
- [ ] Hostname and SSH key supplied as provisioning data are in effect after first boot (D4).
- [ ] Two fresh installations hold different generated secrets, and no account accepts a preset password (D5, D6).
- [ ] A port scan from outside the VM finds only 8080 and 8000, plus SSH only when a key was supplied (G1, G2, G3).
- [ ] Repeated failed logins from one address at the web UI and at the administrative access lead to a block of that address, and the block ends after the configured time, without user action (G8, G10).
- [ ] While one source floods the appliance with connections, a second source still gets answers from the web UI (G9).
- [ ] On a fresh installation the blocking and the rate limit are active without any configuration, and the web UI answers over TLS (G7, G11).
- [ ] The data location spans the available space after first boot and, after a virtual disk is enlarged, offers the added space without reinstalling (E3).
- [ ] All delivery artifacts of one architecture from one CI run report the same system image identifier (H3, H4).
- [ ] The persistent locations are listed, and the appliance returns to service after everything outside them is discarded (A4, E2).
- [ ] A fresh installation starts with every secret the services require; a secret missing from the generated set is generated at the next boot, except one that must stay constant and that a service already started with, which keeps the services stopped until it is restored (D9, D10, D12).
- [ ] A value set in the user file reaches the services after a restart, wins over the generated value, and is still in effect after an update and after a rollback (D11).
- [ ] An invalid value in the user file, also on an indented line, and a changed value of a setting that must stay constant, keep the services stopped with a message naming the value (D12).
- [ ] The backup guidance names the generated secrets, and a restore with them brings back encrypted fields (E5).
- [ ] Without a data disk the appliance installs, starts, and updates as before (E6).
- [ ] A disk named at first start by a `by-id` or `by-uuid` path, as a credential or a setting on the system disk, becomes the data disk with label `kp-data`; a naming or force in the user file on a set-up data disk is ignored with a message; an unnamed disk, a named disk carrying another file system, and the system disk stay untouched even when forced, and the refusal names the signature found (E7).
- [ ] With a data disk, the database volumes, the user file, the generated secrets, and the records of D12 are on it, mounted `nosuid,nodev,noexec` with modes of at most 0700/0600; attached under another device name it is still found; the update state stays on the system disk (E8, E9).
- [ ] A second device labelled `kp-data`, a clone of the data disk with another UUID, and a data disk with a symbolic link at one of its locations, in its pre-update backup directory, or as its release marker each keep the services stopped and are not used; a symbolic link in the backup directory of a disk is never followed (E8, E9).
- [ ] A fresh installation given the same named data disk keeps data, logins, and encrypted fields and generates no secret the disk holds; an unnamed disk labelled `kp-data` is not adopted (E10).
- [ ] An appliance with data on its system disk moves onto a newly named data disk and keeps data, logins, and encrypted fields; a failed health check from the disk returns it to the copy on the system disk; after the keeping period no copy of the moved state is left on the system disk, also not in the configuration of an installed deployment (E11).
- [ ] With the set-up data disk absent or not unlockable the services stay stopped, the message names `kp-data`, and no secret is generated; once the disk is back the services start (E12).
- [ ] An older release keeps the services stopped on a data disk on which a newer release passed its health check; a rollback after a failed or a manual update starts the services normally; the override command works only as root and is recorded (E13).
- [ ] An encrypted data disk opens on later boots without user action; the key is neither in the user file nor on the disk nor in the journal; a key supplied for an unencrypted disk, and a key on the kernel command line, are refused; a container whose data segment uses `cipher_null` is refused (E14).
- [ ] With an encrypted data disk, an unencrypted backup disk is not used (E16).
- [ ] The component list of the release contains no graphical system, no desktop environment, and no development toolchain, and no service runs that the appliance does not use (F1, F2, F3, F4, F5).
- [ ] Idle memory use, installed size, and boot time are recorded for the candidate (F6).
- [ ] Support lifecycle, advisory process, and redistribution terms are documented with their sources (G6, I1, I2, I3).
- [ ] Running version and update state are read through a documented machine-readable interface, and logs stay within their configured size (J1, J2).
- [ ] An installed appliance goes through an update cycle without anyone logging in to the operating system, creating an account, or changing a system setting (A3, K1, K4).
- [ ] The baseline check passes in the build and on an installed appliance, and a baseline change reaches an installed appliance through an update (K2, K3, K5).
- [ ] For each planned target, the drivers and boot modes its documentation requires are present in the image or recorded as missing (H8).

## References

- Sources retrieved 2026-11-12.
- [R1] `docker-compose.release.yml` in `nolte/kamerplanter` (P): <https://github.com/nolte/kamerplanter/blob/develop/docker-compose.release.yml>
- [R2] bootc documentation, release v1.17.4 (P): <https://github.com/bootc-dev/bootc/tree/main/docs/src>
- [R3] Fedora/CentOS bootc documentation, last changed 2026-04-07 (P): <https://docs.fedoraproject.org/en-US/bootc/>
- [R4] image-builder, migration from bootc-image-builder, v90.0.0 (P): <https://github.com/osbuild/image-builder/blob/main/doc/20-advanced/20-bootc/50-migration.md>
- [R5] greenboot-rs README, v0.16.5 (P): <https://github.com/fedora-iot/greenboot-rs/blob/main/README.md>
- [R6] Podman documentation, `podman-systemd.unit(5)` (P): <https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html>
- [R7] Flatcar Container Linux documentation (P): <https://www.flatcar.org/docs/latest/>
- [R8] Flatcar release artifacts, Stable 4757.2.3 (P): <https://stable.release.flatcar-linux.net/amd64-usr/4757.2.3/>
- [R9] transactional-update manual, version 6.2.0 (P): <https://github.com/openSUSE/transactional-update/blob/master/man/transactional-update.8.xml>
- [R10] health-checker README (P): <https://github.com/openSUSE/health-checker>
- [R11] SUSE Linux Micro 6.2, deployment images, published 2026-10-29 (P): <https://documentation.suse.com/sle-micro/6.2/html/Micro-deployment-images/index.html>
- [R12] e2fsprogs, `mke2fs(8)`, option `-L`, retrieved 2026-11-14 (P): <https://man7.org/linux/man-pages/man8/mke2fs.8.html>
- [R13] xfsprogs, `mkfs.xfs(8)`, option `-L`, retrieved 2026-11-14 (P): <https://man7.org/linux/man-pages/man8/mkfs.xfs.8.html>

## Open Questions

- **Which distribution is the base.** The documentation review in Context speaks for `bootc`: it is the only candidate in which the containers' definitions, the configuration, and the security baseline travel with the system update and roll back with it, and in which one image serves every target. Its known risks are the rollback, which rests on an additional package and is unverified under legacy BIOS, the installer ISO tooling in transition, and the amount of own configuration in the image. Flatcar is strongest at the level of the operating system and leaves everything above it to this project; MicroOS has no versioned image. The decision stays open until a prototype has answered the unestablished points, including the choice between Fedora and CentOS Stream as the base of `bootc`.
- **Numeric footprint budgets.** F6 demands measurements but sets no limit, because the resource use of the core services themselves has not been measured and a limit for the base would be arbitrary without it.
- **Firmware per target.** H2 refers to the default firmware of each reference target. `spec/deployment-targets/` §H records that Proxmox VE defaults to SeaBIOS, that Hetzner and OVH do not document their firmware, and that the image therefore has to boot under both legacy BIOS and UEFI. Which candidates offer that together with the rollback of §B has not been checked.
- **Raspberry Pi (deferred).** `spec/deployment-targets/` defers the Raspberry Pi, so H7 leaves aarch64 optional. If the target returns, aarch64 becomes mandatory and the update and rollback behaviour of §B has to hold on a board without UEFI firmware. Which candidates offer that has not been checked; a candidate that cannot would have to be replaced then.
- **Artifact formats.** `spec/deployment-targets/` §C requires an installer ISO and a pre-installed raw disk image. Further formats follow only if more providers become targets there.
- **First start without a registry.** C3 lets the first start load the images from a registry, by decision of the project owner on 2026-11-12. How the appliance behaves when the registry cannot be reached at that moment, such as how long it retries and what the user sees, is undecided.
- **Overrides through provisioning data.** D11 is met in the prototype by a file on the appliance. Setting the same values before the first start through the provisioning data of D4 needs cloud-init or an equivalent in the image, which the prototype does not contain yet.
- **Changing a value that must stay constant.** D12 stops the services when such a value changes. How a user deliberately changes the database password, which the database keeps from its creation, is today a manual sequence: change it in the database, then in the user file, then release the check. Whether the appliance should offer that as one step is undecided.
- **Growing a data disk.** E3 lets the data location grow to the available space on the system disk. Whether the same is required for a data disk of E6, including one encrypted under E14, is undecided; nothing in E6 to E16 depends on it.
- **Rollback after a data migration.** Decided in `spec/update-and-rollback/` D2 and D3: the data is backed up before a new version first starts and restored when it is rolled back.
- **Health check for B3.** Defined in `spec/update-and-rollback/` E1. Found on 2026-11-13 while building it: Fedora 46 packages greenboot 0.15.8, whose boot counter is a snippet in `/etc/grub.d`, and the static GRUB configuration that bootc installs through bootupd does not read that directory (`/usr/lib/bootupd/grub2-static/` in `fedora-bootc:46`). The prototype therefore rolls back on a failed health check with `bootc rollback` itself; a version that does not reach user space is not rolled back yet.
- **Signature check of updates (B6).** Found on 2026-11-13: the containers-policy.json that bootc applies accepts keyless Fulcio signatures only for e-mail identities, not for the workflow identity of a CI build, and does not read the sigstore bundles that cosign v3 writes by default (`image/signature/fulcio_cert.go` in containers/container-libs; PRs #625 and #1153 there are open). The appliance therefore checks updates against a key; see `spec/release-distribution/` D8.
- **One update or two.** B9 prefers one update for the operating system and the containers; B8 prefers the mechanism of the distribution. Where a distribution updates only itself and leaves containers to a registry, the two pull in different directions: one update needs a build and an update source of this project, two updates need none but allow combinations that were never released together. Which weighs more is undecided and is settled with the choice of distribution.
- **Update source.** B10 prefers a project-controlled source; whether there is one, where it is hosted, and how releases are signed is undecided.
- **Which security baseline.** K2 and K5 require a baseline and a check for it, but not which standard it follows. A published benchmark or the hardening guide of the distribution are candidates; the choice depends on the distribution and is undecided.
- **Brute-force and flood protection.** G8 and G9 name fail2ban only as an example. Which tool carries them depends on the distribution, since not every immutable system ships the runtime that fail2ban needs. Also undecided are where failed logins of the Kamerplanter API become visible to the host, and which component terminates TLS and applies the rate limit. The protection covers attacks from few sources; a volumetric attack has to be stopped by the provider or an upstream service.
