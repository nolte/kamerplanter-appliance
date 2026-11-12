# Deployment Targets

Status: draft

## Context

The Kamerplanter appliance is meant to run wherever a single user or a small group wants to host Kamerplanter: on a rented server at a hosting provider such as Hetzner or OVH, on a private virtualisation host running Proxmox VE, or on small private hardware such as a mini PC of the Intel NUC kind. The Raspberry Pi was part of the original intent and is deferred: it is out of scope for now and recorded under Open Questions for later. The user should have as much freedom as possible in choosing where the appliance runs, because the value of the appliance does not lie in the place: it lies in removing the operating overhead of a server, such as patching, user management, and security baselining, and that has to hold wherever it runs. This spec states which environments the appliance has to be installable in and what each of them demands, so that the build, the choice of distribution, and the documentation all aim at the same set of targets.

The targets come from the project owner's statement of intent. Established by `docker buildx imagetools inspect` on 2026-11-12: `ghcr.io/nolte/kamerplanter-backend:0.4.2` and `ghcr.io/nolte/kamerplanter-frontend:0.4.2` are published for `linux/amd64` only, while `arangodb:3.12` and `valkey/valkey:9-alpine` are published for `linux/amd64` and `linux/arm64`.

Established on 2026-11-12 by reading the providers' own documentation through research agents: no examined provider lets a customer boot a self-built installer ISO through self-service. Hetzner Cloud requires a support request with a download link and manual network configuration in the installer [R1][R2]; the import paths of the others take disk images only. Every examined provider has a self-service path for a pre-installed disk image:

| Provider | Self-service path for a pre-installed disk image | Can a vendor pre-publish the image? |
|----------|--------------------------------------------------|-------------------------------------|
| Hetzner Cloud | Boot the rescue system, write a raw image to the disk, take a snapshot, create servers from it. The API has no image upload [R3]. Hetzner's Packer plugin and a community tool automate the steps [R5][R6]. | No. Snapshots can be moved to another project but not shared or published [R3][R4]. |
| OVHcloud Public Cloud | Upload a raw or qcow2 image through the OpenStack CLI or Horizon [R7]. | Only to named projects, per region, with acceptance by the recipient [R8]. |
| OVHcloud dedicated servers | "Bring Your Own Image": OVH fetches a raw or qcow2 image from a URL and writes it to the first disk [R9]. | A published image URL is enough. |
| OVHcloud VPS | None documented by OVH. A rescue mode exists, writing an image from it is not described [R10]. | No. |
| AWS EC2 | Upload to S3, import as a snapshot, register it as an AMI [R11]. | Yes, as a public AMI, copied per region [R12]. |
| Microsoft Azure | Upload a fixed-size VHD and create an image version in a Compute Gallery [R13]. | Yes, through a community gallery [R14]. |
| Google Cloud | Upload `disk.raw` in a gzipped tar to Cloud Storage and create an image from it [R15]. | Yes, to all authenticated users, globally [R16]. |

AWS, Azure, and Google Cloud are planned targets by decision of the project owner on 2026-11-12: they belong to the scope and are connected fully after the reference targets (see §A). Unestablished: whether any of these paths works with the appliance image, since none was tried; which firmware the Hetzner Cloud x86 servers boot with, which Hetzner's documentation does not state; and how much CPU, memory, and storage the core services need. The quotes behind the table were taken from the fetched pages and not compared byte for byte with the originals.

The reference targets for hosted and private VMs share a common base, which §H makes mandatory. Established from the research above and from the Proxmox VE documentation, version 9.2.13:

| Property | Hetzner Cloud | OVHcloud Public Cloud | Proxmox VE | Common base |
|----------|---------------|-----------------------|------------|-------------|
| Accepted artifact | Raw image written from the rescue system [R3] | Raw or qcow2 upload [R7] | Import of a raw, qcow2, or vmdk image; installer ISO [R18] | Raw disk image |
| Disk device | virtio [R20] | virtio-scsi in OVH's example [R7] | VirtIO SCSI for new Linux VMs in the web interface, an emulated LSI controller as the command-line default [R17][R18] | virtio-scsi, plus the emulated default of Proxmox VE |
| Network device | virtio [R20] | Not documented | Intel E1000 by default, VirtIO recommended [R17] | virtio-net, plus E1000 |
| Firmware | Not documented | Not documented | SeaBIOS by default, OVMF selectable [R17][R18] | Legacy BIOS, and UEFI as well |
| Network configuration | IPv4 through DHCP [R21] | Through metadata; DHCP not documented | Not supplied by the platform without cloud-init [R19] | DHCP client |
| Provisioning data | Metadata server read by cloud-init [R3] | Metadata server read by cloud-init [R22] | Optional cloud-init drive in NoCloud format [R19] | cloud-init-compatible source, not guaranteed to exist |

Outside the common base are the installer ISO, which only Proxmox VE and mini PCs accept, drivers for physical hardware, which only mini PCs and OVHcloud dedicated servers need, and OVHcloud VPS, for which OVH documents no path.

Boundaries: `spec/distribution-requirements/` owns what the base distribution has to provide. This spec owns where the appliance runs and what differs between those places. Application behaviour belongs to `nolte/kamerplanter`.

Readers: maintainers who build and release the appliance, reviewers who decide whether a release may claim a target, and authors of the installation documentation.

## Goals

- One appliance serves hosted servers, private virtualisation, and small private hardware, and leaves the user as free as possible in choosing among them.
- The operating overhead is equally low on every target: no patching, no user management, and no baselining by the user anywhere.
- A user chooses a target by what they own or rent, not by what the appliance happens to support.
- The appliance behaves the same on every target; only the way it gets onto the machine differs.
- Every target a release claims has been verified with that release.

## Non-Goals

- Managed platforms: Kubernetes services, container-as-a-service offerings, and platform-as-a-service offerings.
- Clusters or installations spanning several machines.
- Raspberry Pi and other aarch64 machines. They are deferred, not rejected; see Open Questions.
- Architectures other than x86_64.
- A guarantee for every hosting provider, hypervisor, or single-board computer on the market.
- Sizing for the optional services (`vectordb`, `ollama`, `timescaledb`).

## Requirements

### A. Target classes

- **A1 MUST** be installable in three target classes: hosted VM (a virtual server rented from a provider), private VM (a guest on a hypervisor the user runs), and private hardware (a small physical machine the user owns).
- **A2 MUST** treat these as reference targets: Hetzner Cloud and OVHcloud for hosted VM, Proxmox VE for private VM, and x86_64 mini PCs of the Intel NUC kind for private hardware.
- **A3 MUST** offer the same services, the same update mechanism, and the same version on every target; differences are limited to artifact format, hardware enablement, and provisioning input.
- **A4 SHOULD** run on other targets of the same class without target-specific changes.
- **A5 MUST** distinguish in its documentation between reference targets, which are verified, planned targets, which are announced but not yet verified, and other targets, which are only expected to work.
- **A6 MUST NOT** depend on a provider-specific service or API for its operation.
- **A7 MUST** treat AWS EC2, Microsoft Azure, and Google Cloud as planned targets: hosted VM targets that are connected after the reference targets.
- **A8 MUST NOT** take a design decision for the reference targets that rules out a planned target.
- **A9 MUST** promote a planned target to a reference target only once the verification of §G is in place for it.

### B. Architectures

- **B1 MUST** support x86_64 in all three target classes.
- **B2 MUST** run only container images published for the architecture of the machine, without CPU emulation.

### C. Delivery artifacts

- **C1 MUST** provide an installer ISO for private VMs.
- **C2 MUST** install on x86_64 mini PCs from the same ISO written to a USB medium.
- **C3 MUST** provide for hosted VMs a pre-installed disk image in raw format that the user can deploy with the provider's self-service means, without a support request.
- **C4 MUST** build all artifacts of a version from one source definition, as `spec/distribution-requirements/` §H requires.
- **C5 MUST** publish every artifact with a checksum and a signature.
- **C6 MUST** derive every provider-specific image format from the one raw disk image instead of from a separate build.

### D. Hardware and platform

- **D1 MUST** run on hosted and private VMs with the virtual devices that the reference platforms assign by default.
- **D2 MUST** run on x86_64 mini PCs with wired Ethernet and internal SATA or NVMe storage.
- **D3 SHOULD** allow the data location to reside on a different storage device than the system.
- **D4 MUST** operate with wired Ethernet alone.
- **D5 MAY** support Wi-Fi on private hardware.
- **D6 MUST** publish minimum CPU, memory, and storage per target class, based on measurement.
- **D7 MUST** run the core services without a GPU.
- **D8 MUST** return to service after an abrupt power loss on private hardware without manual repair.

### E. Setup per environment

- **E1 MUST** take hostname, network configuration, and administrator SSH key from the instance metadata of the provider on hosted VMs.
- **E2 MUST** come up through DHCP on private VMs and private hardware without any provisioning data.
- **E3 MUST** run on private hardware without a monitor or keyboard attached once it is installed.
- **E4 SHOULD** announce itself in the local network under a fixed name, so that the user finds the web UI without looking up an address.

### F. Network exposure

- **F1 MUST** offer TLS for the web UI and the API on hosted VMs.
- **F2 MUST NOT** serve the web UI or the API over unencrypted HTTP on a public address unless the user decided so explicitly.
- **F3 MUST** work on private targets without inbound reachability from the internet, a public DNS name, or port forwarding.
- **F4 MUST** obtain updates over outbound connections alone.
- **F5 MUST** keep the core services working without internet connectivity once the first start has completed.
- **F6 SHOULD** support IPv4 and IPv6.

### G. Verification

- **G1 MUST** install and smoke-test every release on every reference target before publication.
- **G2 SHOULD** automate that verification for hosted and private VMs.
- **G3 MAY** verify private hardware manually, with a written record per release.
- **G4 MUST** publish a compatibility list naming target, architecture, artifact, and the last verified version.

### H. Common base of the reference targets

- **H1 MUST** provide the pre-installed raw disk image as the artifact that every hosted VM and private VM reference target accepts.
- **H2 MUST** boot that image as a KVM guest with virtio storage and network devices.
- **H3 MUST** boot that image with the devices that Proxmox VE assigns by default, including the emulated ones.
- **H4 MUST** boot that image under legacy BIOS and under UEFI.
- **H5 MUST** obtain its IPv4 configuration through DHCP without user action.
- **H6 MUST** read provisioning data from the cloud-init-compatible source of the target when one is present.
- **H7 MUST** start and complete its first-boot setup when no provisioning data is present.
- **H8 MUST** fit the smallest disk that a reference target offers and grow to the available disk at first boot.
- **H9 MUST NOT** depend on an image that the vendor shares or publishes inside a provider.
- **H10 MUST** meet H1 to H9 with the same system content on every target; the installer ISO, drivers for physical hardware, and provider-specific formats extend that content and do not replace it.

## Acceptance Criteria

The criteria roll several requirements together; every requirement stays normative on its own.

- [ ] One release installs on Hetzner Cloud, OVHcloud, Proxmox VE, and an x86_64 mini PC, and the web UI answers on each (A1, A2, B1).
- [ ] Every one of those installations reports the same appliance version and runs the same set of core services (A3).
- [ ] The installation on each hosted reference target uses only the provider's self-service interface (C3).
- [ ] The appliance runs on a hosted VM with the provider API unreachable (A6).
- [ ] The documentation names AWS EC2, Microsoft Azure, and Google Cloud as planned and claims none of them as verified (A5, A7).
- [ ] For each planned target, a written record states which of its documented image requirements the current image meets and which it does not (A8).
- [ ] A target appears as a reference target only in releases whose compatibility list carries a verified version for it (A9).
- [ ] No container runs under CPU emulation (B2).
- [ ] The ISO installs a Proxmox VE guest and, written to a USB medium, an x86_64 mini PC (C1, C2, D1, D2).
- [ ] All artifacts of a release come from one build run, each provider-specific format is converted from the raw disk image, and each artifact carries a checksum and a valid signature (C4, C5, C6).
- [ ] A hosted VM is reachable by SSH with the key supplied at creation, under the hostname supplied at creation, without console access (E1).
- [ ] An installed mini PC with only power and Ethernet attached boots to a working web UI (D4, E2, E3).
- [ ] The core services run on a machine without a GPU (D7).
- [ ] After power is cut during operation on private hardware, the web UI answers again without manual intervention (D8).
- [ ] The web UI and the API of a hosted VM answer over TLS, and plain HTTP on the public address is refused in the default configuration (F1, F2).
- [ ] A private installation behind NAT with no port forwarding receives an update (F3, F4).
- [ ] With the internet connection removed after the first start, the core services keep answering, also across a reboot (F5).
- [ ] The documentation lists the minimum resources per target class and which targets are verified (A5, D6).
- [ ] The compatibility list for the release names every reference target with architecture, artifact, and verified version (G1, G4).
- [ ] The raw disk image boots to a working web UI on Hetzner Cloud, on the OVHcloud reference product, and on Proxmox VE, and all three report the same system image identifier (H1, H2, H10).
- [ ] On Proxmox VE the image boots in a VM created with the default devices and in one with VirtIO devices, under SeaBIOS and under OVMF (H3, H4).
- [ ] The image obtains its address through DHCP, applies hostname and SSH key where the target supplies provisioning data, and completes first-boot setup on a Proxmox VE VM without a cloud-init drive (H5, H6, H7).
- [ ] The image fits the smallest server type of each hosted reference target and uses the whole disk after first boot (H8).
- [ ] No installation path relies on an image published by the vendor inside a provider (H9).

## References

- Sources retrieved 2026-11-12.
- [R1] Hetzner Docs, "Cloud-ISO installation - configure gateway", last changed 2023-12-28 (P): <https://docs.hetzner.com/cloud/servers/iso-installation-gateway/>
- [R2] Hetzner Docs, Cloud server FAQ, "How can I get a custom ISO?", last changed 2024-09-12 (P): <https://docs.hetzner.com/cloud/servers/faq#how-can-i-get-a-custom-iso>
- [R3] Hetzner Cloud API reference, Images and Server Actions (P): <https://docs.hetzner.cloud/>
- [R4] Hetzner Docs, Backups and Snapshots FAQ, last changed 2022-08-23 (P): <https://docs.hetzner.com/cloud/servers/backups-snapshots/faq/>
- [R5] Packer plugin for Hetzner Cloud, maintained by Hetzner (P): <https://github.com/hetznercloud/packer-plugin-hcloud>
- [R6] `hcloud-upload-image`, community tool without Hetzner support (P): <https://github.com/apricote/hcloud-upload-image>
- [R7] OVHcloud Docs, uploading your own image to Public Cloud (P): <https://docs.ovhcloud.com/en/guides/public-cloud/compute/upload-own-image>
- [R8] OVHcloud Docs, sharing images between projects (P): <https://docs.ovhcloud.com/en/guides/public-cloud/compute/share-images-between-projects>
- [R9] OVHcloud Docs, Bring Your Own Image, updated 2026-08-05 (P): <https://docs.ovhcloud.com/en/guides/bare-metal-cloud/dedicated-servers/bring-your-own-image>
- [R10] OVHcloud Docs, VPS rescue mode, updated 2026-09-07 (P): <https://docs.ovhcloud.com/en/guides/bare-metal-cloud/virtual-private-servers/rescue>
- [R11] AWS VM Import/Export, importing a disk as a snapshot (P): <https://docs.aws.amazon.com/vm-import/latest/userguide/vmimport-import-snapshot.html>
- [R12] Amazon EC2, making an AMI public (P): <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/sharingamis-intro.html>
- [R13] Microsoft Learn, preparing a generic Linux image for Azure (P): <https://learn.microsoft.com/en-us/azure/virtual-machines/linux/create-upload-generic>
- [R14] Microsoft Learn, sharing images through a community gallery (P): <https://learn.microsoft.com/en-us/azure/virtual-machines/share-gallery-community>
- [R15] Google Cloud, manually importing boot disk images (P): <https://cloud.google.com/compute/docs/import/import-existing-image>
- [R16] Google Cloud, managing access to custom images (P): <https://cloud.google.com/compute/docs/images/managing-access-custom-images>
- [R17] Proxmox VE Administration Guide, "QEMU/KVM Virtual Machines", version 9.2.13 (P): <https://pve.proxmox.com/pve-docs/chapter-qm.html>
- [R18] Proxmox VE, `qm(1)` manual page, version 9.2.13 (P): <https://pve.proxmox.com/pve-docs/qm.1.html>
- [R19] Proxmox VE wiki, "Cloud-Init Support", last edited 2025-11-19 (P): <https://pve.proxmox.com/wiki/Cloud-Init_Support>
- [R20] Hetzner Docs, Cloud technical details FAQ, last changed 2024-06-25 (P): <https://docs.hetzner.com/cloud/technical-details/faq/>
- [R21] Hetzner Docs, static IP configuration, last changed 2024-06-12 (P): <https://docs.hetzner.com/cloud/servers/static-configuration/>
- [R22] OVHcloud Docs, Public Cloud FAQ (P): <https://docs.ovhcloud.com/en/guides/public-cloud/cross-functional/faq-pci>

## Open Questions

- **Raspberry Pi (deferred).** Out of scope by decision of the project owner on 2026-11-12, to be taken up later. What is known for that point: the Kamerplanter backend and frontend images are published for `linux/amd64` only (see Context), so `nolte/kamerplanter` has to publish aarch64 images first. Bringing the target back means adding aarch64 as a second architecture released together with x86_64, an image that is written to the boot medium and starts without an installer step, a named list of supported models, a decision on SD card versus USB or NVMe storage, and setup without monitor or keyboard.
- **Minimum resources.** D6 demands published minimums; none exist because nothing has been measured.
- **Import on Hetzner Cloud.** No vendor can publish an image there, so every user has to import the disk image into their own project. Whether the documented way is Hetzner's Packer plugin or the community tool is undecided, and neither was tried. Hetzner does not guarantee that cloud-init provisioning works on a system installed through the rescue system, which E1 depends on.
- **Boot mode of the disk image.** H4 demands both boot modes because the firmware is not known for two of the three targets. Hetzner's documentation does not state the firmware of its x86 servers, and a third-party source reports legacy BIOS; OVH's does not state it either; Proxmox VE defaults to SeaBIOS [R17]. Among the planned targets, AWS defaults to legacy BIOS on x86 and the Google Cloud import page demands an MBR bootloader. That one image boots under both has not been verified.
- **One image or one image per target.** H10 demands the same system content everywhere. Some immutable distributions fix the provisioning platform inside the image, so that each target needs its own variant with otherwise identical content. Whether such variants satisfy H10 and C6 is undecided and depends on the distribution chosen.
- **Connecting the planned targets.** AWS, Azure, and Google Cloud each have a self-service import path and allow public sharing without a marketplace listing. Connecting them means one more artifact format each (Azure needs a fixed-size VHD, Google Cloud a `disk.raw` in a tar archive), provider-specific drivers and provisioning clients in the image, and an account per provider for the verification under G1. Their order and timing are undecided. One uncertainty is known: the AWS import path that checks the operating system accepts listed distributions only, and the documentation does not state that the snapshot path accepts an unlisted one.
- **Which OVH products.** OVHcloud sells VPS, Public Cloud instances, and dedicated servers. Public Cloud and dedicated servers have a documented path for a custom image, VPS has none. Which of them count as the reference target is undecided.
- **TLS on hosted VMs.** F1 requires TLS, but a publicly trusted certificate needs a DNS name the user controls. Whether the appliance obtains certificates itself or starts with a self-signed one is undecided.
- **Backup on private hardware.** Virtualised targets can rely on hypervisor snapshots. Private hardware has none, and how the user backs up the data location there is undecided.
- **Verification hardware.** G1 requires a test on real private hardware for every release. Which devices are available for that, and who runs the test, is undecided.
