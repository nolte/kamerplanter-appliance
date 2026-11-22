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
| Same content on every target (deployment-targets H10) | Yes, with cloud-init added to the image (L1) | Identical system, one small variant per target | Only with an own image profile |
| Installer ISO (D1, D2) | Possible; the tooling is in transition | The official ISO is a BIOS-only live system; an own installer is needed | Unattended self-install ISO from the same build as the raw image |
| Legacy BIOS and UEFI (deployment-targets H4) | Hybrid partition layout, not stated as supported | Both boot loaders in the same image | MicroOS only in its GRUB2 variant; SUSE documents Micro 6.2 as UEFI only |
| Devices that Proxmox VE assigns by default (deployment-targets H3) | Fedora builds both drivers; CentOS Stream does not build the LSI driver | Both drivers are in the initrd of the release | Not documented |
| Mandatory access control enforcing (G5) | Yes | No, permissive by default, with limits for shared volumes | Yes |
| Firewall with default deny (G1) | To be added | To be added | To be added in MicroOS |
| Support lifecycle (I1) | Fedora about 13 months per release; CentOS Stream 10 until 2030-05-31 | A stable channel without fixed end dates, an LTS channel of 18 months | MicroOS rolling; the status of Leap Micro is unclear |

Established on 2026-11-13 from the upstream documentation (`docs/de/deployment/konfigurationsmatrix.md`, `docs/de/reference/environment-variables.md`, `docs/de/deployment/backup-restore.md` in a working copy of `nolte/kamerplanter`) and from the first prototype runs: with `DEBUG=false` the backend refuses to start without `JWT_SECRET_KEY`, `ARANGODB_PASSWORD`, `FERNET_KEY`, `ERASURE_TOMBSTONE_SALT`, and `LOG_PSEUDONYM_SALT`, while the upstream `.env.example` names only the database password and the two salts, and the release Compose file passes neither `JWT_SECRET_KEY` nor `FERNET_KEY`. The upstream documentation states that `ERASURE_TOMBSTONE_SALT` must never change and that data encrypted with `FERNET_KEY` and deletion records depend on these values after a restore. A probe with the pinned ArangoDB image showed that it takes `ARANGO_ROOT_PASSWORD` only when the database is first created: after a restart with another value, the old password still logs in and the new one is refused.

Established on 2026-11-14 by a feasibility spike for an optional data disk (a VM booted from the prototype's disk image with a second disk attached, on a GitHub-hosted runner with KVM): bind mounts from the data disk onto `/etc/kamerplanter`, `/var/lib/kamerplanter/pinned`, and the two database volume directories keep working across a new deployment that runs the ostree `/etc` merge and across a rollback; content written after the move stays on the data disk and is not copied into the `/etc` of any deployment on the system disk; a fresh appliance given the same disk uses its secrets and data unchanged. ext4 file system labels hold at most 16 characters [R12] and xfs labels 12 [R13], which the spike confirmed when `mkfs.ext4` truncated `kamerplanter-data`; the labels are therefore `kp-data` and `kp-backup`. The spike ran as workflow `spike-data-disk`, run 43605692183. It did not cover LUKS2 or the TPM, the move of a running appliance, or a USB stick. The base image ships `mkfs.ext4`, `cryptsetup`, `systemd-cryptenroll`, and the TPM2 tools.

Established on 2026-11-14 by a feasibility spike for provisioning data (issue #17; workflow runs 43611879282, 43626093374, and 43640039007 on the branch `exp/provisioning-spike`, a QEMU VM on a GitHub-hosted runner booted from the prototype image with cloud-init 26.2 added): `bootc container lint` passes with cloud-init installed, with three warnings about content in `/run` and `/tmp`, a non-empty `/var/log`, and content in `/var` without a tmpfiles.d entry. Without any source, cloud-init's generator disables it, and the appliance comes up through DHCP and completes its first-boot setup as before. A drive labelled `CIDATA`, as ISO 9660 image and as vfat, and a seed URL in the SMBIOS serial number are detected; the hostname, a file from `write_files`, and an SSH key for root take effect, although cloud-init warns that it failed to set the hostname. Seed files under `/var/lib/cloud/seed/nocloud/` are not detected while more than one datasource is listed, because ds-identify decides at 2.5 s and `/var` is mounted at 3.68 s; with `datasource_list: [ NoCloud, None ]` ds-identify takes that single entry without detection and the seed files are read. A static network configuration whose network-config version 2 entry uses `match:` without `set-name:` yields a NetworkManager keyfile bound to the entry's name instead of the device, which never activates, so NetworkManager keeps its default DHCP connection. The stock configuration creates a user `fedora`; `cc_resizefs` warns about `/dev/composefs`; the top-level key `kamerplanter:` makes `cloud-init schema` fail and the status `degraded done` on every run. cloud-init keeps the user-data, and every secret in it, in `user-data.txt`, `user-data.txt.i`, `cloud-config.txt`, and `obj.pkl` under `/var/lib/cloud/instances/<id>/` and in `/run/cloud-init/combined-cloud-config.json`, and not in the journal; once deleted, these copies return on the next boot while the source stays attached. An nftables rule `ip daddr 169.254.169.254 meta skuid != 0 drop` lets root reach a metadata double and blocks the user `nobody` and the backend container; nftables 1.1.6 is in the image, firewalld is not. A system credential `kamerplanter.secret.JWT_SECRET_KEY`, passed as an SMBIOS type 11 string, reaches a unit through `ImportCredential=kamerplanter.secret.*` and does not appear in the journal. Established by reading the source of cloud-init 26.2: ds-identify selects the datasource named by `ds=` on the kernel command line without detection (`tools/ds-identify`, lines 2148 to 2157), which the spike did not boot; `write_files` runs once per instance (`cloudinit/config/cc_write_files.py`, line 29). Unestablished: the Hetzner and OpenStack datasources, which the spike did not exercise for lack of a metadata double, and which datasource serves the metadata of OVHcloud.

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
- A command on the appliance that rotates secrets (L18).

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
- **D4 MUST** accept machine-readable provisioning data at first boot for hostname, network, and an administrator SSH key, from the sources of L2: a NoCloud drive labelled `CIDATA`, a NoCloud seed URL on the kernel command line or in the SMBIOS serial number, NoCloud seed files on the system disk, and the metadata services of Hetzner Cloud and OVHcloud.
- **D5 MUST** provide a hook that runs a one-shot step at first boot before the containers start.
- **D6 MUST NOT** ship preset credentials for any operating-system account or any service.
- **D7 MUST** configure the network through DHCP by default and allow a static configuration.
- **D8 MUST** be deliverable as a pre-installed image that boots directly from the medium it was written to, for targets without an installer step.
- **D9 MUST** generate every secret that the Kamerplanter services require, individually per installation, and keep it across updates and rollbacks.
- **D10 MUST** generate a secret that a later release newly requires at the first boot of that release, without user action.
- **D11 MUST** let the user override every generated secret and every setting of the services, before or after the first start, in one documented file that survives updates and rollbacks. The effective configuration is built from four layers, a later one winning: the defaults of the image, the provisioning layer of L10, the secrets file (generated under D9 and D10, or taken over under L12 and L13), and that file.
- **D12 MUST** check the effective configuration before the services start and keep them stopped with a message that names the faulty value, when a value is invalid, or when a value that must stay constant once a service has started with it has changed or is missing. A whole number is invalid also beyond the range its reader processes: `UPDATE_HEALTH_TIMEOUT` outside 1 to 9999 minutes, `UPDATE_BACKUP_KEEP_DAYS` beyond six digits. A provisioned `JWT_SECRET_KEY` shorter than 32 characters and a provisioned `ARANGODB_PASSWORD` shorter than 16 characters are invalid until a service has first started (L11, L12, L13); the same value in the user file or the secrets file, or a provisioned one once a service has started, MUST instead be warned about, naming the key and never the value, so that an installation running with it keeps starting and its updates are not rolled back.
- **D13 MUST** derive each of `FRONTEND_URL` and `CORS_ORIGINS` that no layer of D11 sets, once the configuration check of D12 has passed, on every boot, after `network-online.target` (also when it is reached without a network), and on every `systemctl restart kamerplanter.target`, from how the appliance is reached at that moment: its static host name, as `/etc/hostname` holds it from the provisioning data (L5) or from the user, and its global IPv4 and IPv6 addresses. It MUST NOT use the transient host name, which a DHCP server can supply when no static one is set, and MUST leave out a host name that is `localhost`, `localhost.localdomain`, or no valid DNS name, the addresses of the container networks, and IPv6 addresses that are temporary, deprecated, tentative, or failed duplicate address detection. The derived `FRONTEND_URL` is `http://<host name>:8080` for a host name with a dot, otherwise `http://<first IPv4 address>:8080`, otherwise `http://<host name>:8080`, otherwise `http://localhost:8080`. The derived `CORS_ORIGINS` lists, each once: the origin of a `FRONTEND_URL` that a layer sets, written as a browser sends it (in lower case, without the default port of its scheme); the origin of the `FRONTEND_URL` derived as above; and `http://<name>:8080` for the host name, for the host name with `.local` when it has no dot, for every address, and last for `localhost`. A key that any layer sets, also to an empty value, MUST be used as it is, with nothing derived for it, so that an upgraded installation keeps the values it runs with. The derivation MUST NOT keep the services stopped: a non-empty `FRONTEND_URL` set in a layer from which no `http` or `https` origin can be read adds none, with a warning in the journal, and without a usable host name or address the values end at `localhost`. The journal MUST name each derived value. An address that arrives after the derivation becomes an origin only at the next boot or `systemctl restart kamerplanter.target` (see Open Questions).

### E. State and data

- **E1 MUST** keep all persistent state in a location separate from the system image, untouched by updates and rollbacks.
- **E2 MUST** make the set of persistent locations enumerable, so that everything outside it can be discarded and reproduced. With a data disk (E6), the locations on it belong to that set.
- **E3 MUST** let the data location grow to the available space, at first boot and after a virtual disk is enlarged, without reinstalling.
- **E4 SHOULD** support consistent backups through hypervisor snapshots on virtualised targets, including a filesystem freeze through a guest agent.
- **E5 MUST** keep the generated secrets in the persistent state, on the data disk of E6 when one is set up and on the system disk otherwise, and name them in the backup guidance, since data restored without them loses its encrypted fields and deletion records.
- **E6 MAY** keep the persistent state of E9 on an optional, separate local data disk: a second virtual disk, a second internal drive, a USB disk, or a USB stick. E7 to E16 apply only when a data disk or a backup disk is set up; without one, the persistent state stays on the system disk as before.
- **E7 MUST** format a disk as data disk (ext4, label `kp-data`) or as backup disk (ext4, label `kp-backup`, see `spec/update-and-rollback/` D8) only when it is named explicitly by a `/dev/disk/by-id/` or `/dev/disk/by-uuid/` path, from the system side only: as the system credential of the same name, or as a setting kept on the system disk; the provisioning layer of L10 is not such a setting (L19). The user file of D11 MAY name a disk only while no data disk is set up; while one is, the user file lies on that disk, and its naming and forcing settings MUST be ignored with a message that says where to set them instead. It MUST refuse a named disk that carries another file system or partition table, naming the signature found, unless the naming explicitly forces the format; a forced format applies once to the named device, whatever path names it, and is never repeated for a device that already carries `kp-data` or `kp-backup`. It MUST NOT format the disk that holds the running system, any of its partitions, or a mounted device, even when forced.
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

### L. Provisioning data

L1 to L20 state how the appliance reads the provisioning data of D4 and takes Kamerplanter settings and secrets from it. Without provisioning data, none of them changes the behaviour of the appliance (L4).

- **L1 MUST** contain cloud-init in the system image, with its full module set enabled, as the client for the provisioning data of D4.
- **L2 MUST** read provisioning data, when present, from the NoCloud datasource in each of its forms: a drive labelled `CIDATA` (a virtual drive, or a USB stick on private hardware); a seed URL given as `ds=nocloud;s=<URL>` on the kernel command line or in the SMBIOS system serial number; and seed files under `/var/lib/cloud/seed/nocloud/`, as L3 states. On Hetzner Cloud and OVHcloud it MUST read them from the metadata service of the provider.
- **L3 MUST** read seed files under `/var/lib/cloud/seed/nocloud/` when they come with a configuration file under `/etc/cloud/cloud.cfg.d/` that sets `datasource_list: [ NoCloud, None ]`, and the documentation MUST name that file as part of supplying seed files. cloud-init decides which datasource to use before `/var` is mounted and therefore does not find the seed files while it chooses among several datasources (see Context). The image MUST NOT ship that file itself, since cloud-init would then run on every boot, also without provisioning data (L4), and would no longer read the metadata services of L2.
- **L4 MUST**, when no provisioning data is present, leave cloud-init disabled, come up through DHCP, and complete its first-boot setup as it does without cloud-init (D7; `spec/deployment-targets/` E2, H7).
- **L5 MUST** apply the hostname, the network configuration, such as a static IPv4 address, gateway, and DNS servers, and the SSH keys of the provisioning data at boot. It MUST authorise the provisioned SSH keys for root, create no default user, the distribution's stock `default_user` included, set `ssh_pwauth: false`, and keep password login refused even when the provisioning data asks for it (G3).
- **L6 MUST** support a static network configuration given as cloud-init network-config version 2 with each `ethernets` entry keyed by the name of the interface on the appliance, and as version 2 with `match: macaddress:` together with `set-name:`. A `match:` without `set-name:` is not supported, since cloud-init then binds the connection to the entry's name and it never activates (see Context). Whether the two supported forms activate and take precedence over NetworkManager's default DHCP connection, and whether the network configuration that Proxmox VE generates for its cloud-init drive works, is unestablished; the documentation MUST name a form as supported only once a boot test has shown it working.
- **L7 MUST** keep cloud-init from growing partitions and file systems by default: the image's configuration sets `growpart` to `mode: off` and `resize_rootfs` to `false`, and both modules stay in the module set of L1. Growing the data location stays with E3 and `spec/deployment-targets/` H8.
- **L8 MUST NOT** treat the status `degraded done` that cloud-init reports because of the top-level key `kamerplanter:` of L9 as a failure, in any unit, check, or health check of the appliance, and the documentation MUST state that this schema warning is expected. The key stays the carrier of the settings and secrets, because it is the documented interface; whether a schema extension could avoid the warning is unestablished.
- **L9 MUST** accept Kamerplanter settings from the provisioning data in two forms: a map `kamerplanter:` → `settings:` in the cloud-config, which is the documented interface, and the file `/var/lib/kamerplanter/provisioning/provisioning.env`, in the format of the user file of D11, written by cloud-init's `write_files`. For a key that both set, the map wins. Neither form ever writes the user file of D11.
- **L10 MUST** apply the provisioned settings on every boot as a configuration layer of their own, the provisioning layer, between the defaults of the image and the secrets file (D11), and every component that reads the configuration MUST load the same layers in the same order. It MUST keep the provisioning layer on the system disk, owned by root with mode 0600 in a directory of mode 0700, outside `/etc/kamerplanter` and every other location that a data disk binds over (E9), and outside the run-time directory that the configuration check empties when it fails (D12). It MUST renew the layer from the map of L9 on every boot on which provisioning data is available, and keep it unchanged on a boot without, so that the settings stay in effect after the source is detached (L20).
- **L11 MUST** pass every key of the provisioning layer through and check it in the configuration check of D12 like a value of the user file; an invalid provisioned value MUST keep the services stopped with the same message, which names the provisioning layer as its source. A key that names a data or backup disk or forces its format (`DATA_DISK`, `BACKUP_DISK`, `DATA_DISK_FORCE`, `BACKUP_DISK_FORCE`) MUST be ignored with a message that says where to set it instead (L19). A key of the generated secrets of D9 under `settings:` MUST be passed through with a warning that names the key, never its value, and points to `secrets:`.
- **L12 MUST** accept secrets from a map `kamerplanter:` → `secrets:` in the cloud-config and take them into the secrets file of D11 once per provisioning instance: on the first boot on which the configuration step can write that file, and on every boot until then on which the source supplies them. It MUST fill only keys that the secrets file does not hold; when a provisioned secret differs from a value the secrets file holds, also in a secrets file adopted from a data disk (E10), it MUST keep that value, log a warning that names the key, never the value, and start the services as usual. It MUST NOT write a provisioned secret into the provisioning layer, the journal, the console, or the output of any command. A secret taken over is a secret of D9 from then on, kept across updates and rollbacks and on the data disk when one is set up (E5, E9).
- **L13 MUST**, on Proxmox VE and on any other QEMU guest, accept a secret as the system credential `kamerplanter.secret.<KEY>`, one credential per key, for example as an SMBIOS type 11 string, and fill a key that the secrets file does not hold with it on any boot, under the conflict rule of L12. When a credential and the map of L12 supply the same missing key, the credential wins. The documentation MUST state how Proxmox VE passes such a credential and which permission that requires.
- **L14 MUST** keep generating, under D9 and D10, every secret that no layer holds and no provisioned secret supplies; a key that any layer holds counts as present. The rules of D12 for values that must stay constant, `ERASURE_TOMBSTONE_SALT`, `FERNET_KEY`, and `ARANGODB_PASSWORD`, MUST apply unchanged to provisioned values: a provisioned value restores a missing pinned key only when it matches the recorded value, and otherwise keeps the services stopped.
- **L15 MUST**, on every boot, once the provisioning layer is renewed and the secrets are taken over, delete every copy of the user-data that cloud-init keeps under `/var/lib/cloud` and `/run/cloud-init`, and every provisioned secret in cloud-init's logs, rotated and compressed ones included, because cloud-init stores the user-data again on each boot while the source stays attached (see Context). A boot that ends before this is done MUST NOT leave a secret behind: a later boot, also one without the source, MUST still find the secrets in what the earlier boot left, or delete cloud-init's logs when it cannot. It MUST keep cloud-init's record of the instance it has set up, so that once-per-instance steps do not run again; whether deleting the copies affects that record is unestablished.
- **L16 MUST** let only root reach the metadata address `169.254.169.254`, on every target: other local users and the containers MUST NOT reach it. The restriction MUST be in effect before the first Kamerplanter container starts.
- **L17 MUST** order a boot so that cloud-init has fetched the provisioning data and run `write_files` before the provisioning step renews the provisioning layer and stages the secrets; the data disk is mounted and bound (E8, E9) before a provisioned secret is written into the secrets file, so that it fills the secrets file of an adopted data disk (E10); and the provisioning step has finished before the configuration check of D12 runs. A provisioned `UPDATE_WINDOW` MUST set the maintenance window of `spec/update-and-rollback/` C1 from the first boot. These orderings MUST NOT make a boot wait for cloud-init when it is disabled (L4). Staged secrets MUST pass from the provisioning step to the configuration step only through a location in memory that root alone can read, and MUST be deleted once taken over.
- **L18 MUST NOT** offer a command of its own that rotates secrets. Later changes go through the user file of D11, or through configuration management outside the appliance, which `nolte/kamerplanter-infrastructure#8` owns.
- **L19 MUST NOT** take the naming of a data or backup disk, the forcing of its format, or its key from the cloud-init provisioning data; E7 and E14 define the channels for them, the system credentials among them.
- **L20 MUST** document the interface (the map `kamerplanter:` with `settings:` and `secrets:`, and the `write_files` target of L9), its lifecycle (L10, L12, and that `write_files` runs once per instance), the secret channels and their protection (L12 to L16), and the hardening steps: detaching the NoCloud drive or removing the seed files after the first boot, deleting provisioning data that holds secrets, such as snippets on Proxmox VE, and that such data lies in plain text until then, on hosted targets with the provider for the life of the server. It MUST warn that cloud-init changes outside the documented interface, such as modules that install packages or write under `/usr`, can interfere with updates and rollbacks.

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
- [ ] Hostname and an SSH key for root supplied as provisioning data are in effect after first boot, from a `CIDATA` drive, from a seed URL in the SMBIOS serial number, and from seed files with the configuration file of L3; a static IPv4 address with gateway and DNS servers from a `CIDATA` drive is in effect and reachable (D4, L2, L3, L5, L6).
- [ ] On Hetzner Cloud and on the OVHcloud reference product, hostname and SSH key from the provider's metadata service are in effect after first boot (D4, L2).
- [ ] Without provisioning data cloud-init stays disabled, the appliance obtains its address through DHCP, and its first boot completes as before (L4).
- [ ] With provisioning data no default account such as `fedora` exists, SSH password login stays refused also when the provisioning data enables it, cloud-init grows no partition, and its status `degraded done` caused by the key `kamerplanter:` fails no unit and no check (L1, L5, L7, L8).
- [ ] Two fresh installations hold different generated secrets, and no account accepts a preset password (D5, D6).
- [ ] A port scan from outside the VM finds only 8080 and 8000, plus SSH only when a key was supplied (G1, G2, G3).
- [ ] Repeated failed logins from one address at the web UI and at the administrative access lead to a block of that address, and the block ends after the configured time, without user action (G8, G10).
- [ ] While one source floods the appliance with connections, a second source still gets answers from the web UI (G9).
- [ ] On a fresh installation the blocking and the rate limit are active without any configuration, and the web UI answers over TLS (G7, G11).
- [ ] The data location spans the available space after first boot and, after a virtual disk is enlarged, offers the added space without reinstalling (E3).
- [ ] All delivery artifacts of one architecture from one CI run report the same system image identifier (H3, H4).
- [ ] The persistent locations are listed, and the appliance returns to service after everything outside them is discarded (A4, E2).
- [ ] A fresh installation starts with every secret the services require; a secret missing from the generated set is generated at the next boot, except one that must stay constant and that a service already started with, which keeps the services stopped until it is restored (D9, D10, D12).
- [ ] A value set in the user file reaches the services after a restart, wins over the generated value and over a provisioned value, and is still in effect after an update and after a rollback (D11).
- [ ] An invalid value in the user file, also on an indented line, and a changed value of a setting that must stay constant, keep the services stopped with a message naming the value (D12).
- [ ] `UPDATE_HEALTH_TIMEOUT=10000` and a `JWT_SECRET_KEY` of 31 characters provisioned before the first start keep the services stopped with a message naming the key; a `JWT_SECRET_KEY` of 31 characters in the user file, or provisioned after the services have started, lets them start with a warning that names the key and not the value (D12).
- [ ] On a booted appliance with no layer setting them, `CORS_ORIGINS` lists `http://<IPv4 address>:8080` and ends with `http://localhost:8080` (boot check `run1-address`); in the unit cases of `tests/unit/provisioning.sh`, a host name with a dot becomes `FRONTEND_URL` and a bare one gives the first IPv4 address, a transient host name, an address of a container network, and a temporary or failed IPv6 address are not used, a set `FRONTEND_URL` leads `CORS_ORIGINS` as a browser sends its origin, without host name and address both end at `localhost`, and a value of the user file or the provisioning layer, also an empty one, is kept with nothing derived for that key (D13).
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
- [ ] `FRONTEND_URL` set under `kamerplanter:` → `settings:` is in effect at the first start of the services without a restart of them; a value set only in the `write_files` file applies; for a key that both set, the map wins; a changed map value applies after the next boot; the settings stay in effect after the source is detached; every component that reads the configuration sees the same values, and a provisioned `UPDATE_WINDOW` sets the maintenance window from the first boot (L9, L10, L17).
- [ ] An invalid provisioned value, such as `UPDATE_WINDOW=25:00`, keeps the services stopped with a message that names the value and the provisioning layer; `DATA_DISK` in the provisioning layer is ignored with a message; a `FERNET_KEY` under `settings:` is used with a warning that names the key and not the value (L11, L19).
- [ ] A secret under `kamerplanter:` → `secrets:` is in the secrets file after the first boot and is not taken over again on a later boot; a value that the secrets file holds already, also on an adopted data disk, is kept with a warning that names only the key; no copy of the secret is found under `/var/lib/cloud`, under `/run/cloud-init`, or in cloud-init's logs, also after a reboot with the drive still attached, and the provisioned settings still apply then (L12, L15, L17).
- [ ] After a boot that ends between cloud-init's last stage and the scrub, a boot without the source leaves no provisioned secret in cloud-init's logs; a rotated log is scrubbed, a compressed one that holds a secret is deleted (L15).
- [ ] A secret passed as the system credential `kamerplanter.secret.<KEY>` fills the missing key of the secrets file, and no provisioned secret appears in the journal or in the output of the configuration check (L12, L13).
- [ ] Without provisioned secrets the secrets file is generated as before; a provisioned value of a pinned key that differs from the recorded value keeps the services stopped, and a matching one restores the missing key (L14).
- [ ] Root reaches `169.254.169.254`; another local user and a container do not (L16).
- [ ] With a data disk set up, the provisioning layer and the `write_files` target lie on the system disk, and a secret taken over at the first boot of a fresh system that adopts the disk lands in the secrets file on the data disk (L10, L17, E10).
- [ ] The documentation describes the interface, its lifecycle, the secret channels and their protection, the hardening steps, the expected `degraded` status, the configuration file for seed files, and the warning about changes outside the interface; the appliance offers no command that rotates secrets and takes no disk naming from cloud-init (L3, L8, L18, L19, L20).
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
- **Overrides through provisioning data.** Decided on 2026-11-14 with issue #17: cloud-init in the image reads the provisioning data of D4, and §L defines the provisioning layer, the secret channels, and their protection.
- **Hosted datasources and static network forms.** Whether cloud-init's Hetzner datasource and the datasource that serves the metadata of OVHcloud work in the appliance unchanged (L2) is unestablished and needs a real target or a metadata double. Which network-config forms of L6 activate, and whether the configuration that Proxmox VE generates works, needs a boot test.
- **Changing a value that must stay constant.** D12 stops the services when such a value changes. How a user deliberately changes the database password, which the database keeps from its creation, is today a manual sequence: change it in the database, then in the user file, then release the check. Whether the appliance should offer that as one step is undecided.
- **Address changes and host-name limits.** D13 reads the addresses once per run of the configuration check, so an address that arrives later, such as an IPv6 address still tentative or a new DHCP lease, is no origin until the next boot or restart; the check waits for the network to be online, also when there is no link. Whether the appliance should re-derive on an address change, list the `.local` origin only when it announces that name, and bound that wait is undecided (#109). A static host name with a dot that clients cannot resolve, such as one ending in `.localdomain`, becomes `FRONTEND_URL` today; that and smaller corrections of the derivation, such as the condition of its warning, the parse of the host name, and the form of an origin, are tracked in #116.
- **Growing a data disk.** E3 lets the data location grow to the available space on the system disk. Whether the same is required for a data disk of E6, including one encrypted under E14, is undecided; nothing in E6 to E16 depends on it.
- **Rollback after a data migration.** Decided in `spec/update-and-rollback/` D2 and D3: the data is backed up before a new version first starts and restored when it is rolled back.
- **Health check for B3.** Defined in `spec/update-and-rollback/` E1. Found on 2026-11-13 while building it: Fedora 46 packages greenboot 0.15.8, whose boot counter is a snippet in `/etc/grub.d`, and the static GRUB configuration that bootc installs through bootupd does not read that directory (`/usr/lib/bootupd/grub2-static/` in `fedora-bootc:46`). The prototype therefore rolls back on a failed health check with `bootc rollback` itself; a version that does not reach user space is not rolled back yet.
- **Signature check of updates (B6).** Found on 2026-11-13: the containers-policy.json that bootc applies accepts keyless Fulcio signatures only for e-mail identities, not for the workflow identity of a CI build, and does not read the sigstore bundles that cosign v3 writes by default (`image/signature/fulcio_cert.go` in containers/container-libs; PRs #625 and #1153 there are open). The appliance therefore checks updates against a key; see `spec/release-distribution/` D8.
- **One update or two.** B9 prefers one update for the operating system and the containers; B8 prefers the mechanism of the distribution. Where a distribution updates only itself and leaves containers to a registry, the two pull in different directions: one update needs a build and an update source of this project, two updates need none but allow combinations that were never released together. Which weighs more is undecided and is settled with the choice of distribution.
- **Update source.** B10 prefers a project-controlled source; whether there is one, where it is hosted, and how releases are signed is undecided.
- **Which security baseline.** K2 and K5 require a baseline and a check for it, but not which standard it follows. A published benchmark or the hardening guide of the distribution are candidates; the choice depends on the distribution and is undecided.
- **Brute-force and flood protection.** G8 and G9 name fail2ban only as an example. Which tool carries them depends on the distribution, since not every immutable system ships the runtime that fail2ban needs. Also undecided are where failed logins of the Kamerplanter API become visible to the host, and which component terminates TLS and applies the rate limit. The protection covers attacks from few sources; a volumetric attack has to be stopped by the provider or an upstream service.
