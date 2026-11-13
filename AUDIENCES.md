# Audiences — Kamerplanter Appliance

<!--
Produced via the `audience-identify` skill, following
spec/project/audience-identification/. Audiences, categories, ranking and
status were chosen by the maintainer on 2026-11-13; expectations and surfaces
are derived from README.md, spec/ and docs/. Do not add audiences without first
declaring the bounded context below.
-->

## Bounded context

The bootable, self-updating appliance that packages Kamerplanter for a single
machine.

**Inside the boundary**

- The system image (`image/`, bootc on Fedora) with the Kamerplanter containers
  as Quadlet units
- First-boot setup and configuration on the device (`/etc/kamerplanter/`, the
  generated secrets, the configuration check)
- The delivery artefacts (raw disk image, later the installer ISO), their
  checksums and signatures, and the build and release workflows
- The update path through the system image in the container registry
- The documentation (`docs/`) and the specifications (`spec/`)

**Outside the boundary**

- The Kamerplanter application itself (`nolte/kamerplanter`, with its own
  `AUDIENCES.md`)
- The Kubernetes / Helm way of running Kamerplanter
- The Home Assistant integration (`nolte/kamerplanter-ha`)
- The planned Terraform modules (own repository)
- The operator's hardware, hypervisor, or hosting account

## Audiences

Each entry: label, relationship category, interaction surface, expectation,
documentation `track` (`user-docs` or `developer-docs` per
spec/project/docs-audience-tracks/), open questions, `confirmed` or `assumed`,
criticality (primary / secondary / peripheral).

Portfolio-baseline track defaults: `user` → `user-docs`; `contributor` /
`operator` / `release-manager` → `developer-docs`.

### Direct consumers

- **Infrastructure-as-code automation** — _category_: direct-consumer ·
  _surface_: release assets (disk image, checksum file, signatures) fetched by
  URL; provisioning data passed to the appliance at first boot ·
  _expects_: stable, versioned asset names, a checksum and signature to verify
  against, documented provisioning inputs (SSH key, host name, own values) ·
  _track_: `developer-docs` · _status_: `assumed` · _criticality_: secondary
  - Open questions: which provisioning mechanism the appliance accepts (cloud-init
    is not in the image yet); whether the Terraform modules live in
    `terraform-proxmox-kamerplanter-appliance` or `kamerplanter-tf-infrastructure`.

### Operators

- **Self-hoster** (ID `self-hoster`) — _category_: operator ·
  _surface_: release page and download verification, the installation guide per
  target, the web UI on port 8080, the API on port 8000, the configuration file
  `/etc/kamerplanter/kamerplanter.env`, `systemctl restart kamerplanter.target` ·
  _expects_: a verified download, a fast first start, no operating-system
  administration (no patching, no user management, no hardening), updates that
  apply and roll back by themselves, clear messages when a setting is wrong,
  backup guidance ·
  _track_: `user-docs` — overrides the operator default `developer-docs`: the
  self-hoster is the end user of the appliance; its whole point is that running
  it needs no operator or developer knowledge ·
  _status_: `confirmed` · _criticality_: primary
  - Homelab: installs on Proxmox VE or an x86_64 mini PC inside the home
    network; reaches the appliance by address or host name.
  - Hosted: runs it at Hetzner, OVH, and later AWS, Azure or Google Cloud with
    a public address; additionally needs the provider-specific import path, TLS,
    and protection against brute force and floods.
  - Open questions: which minimum resources to state per target class (measured
    so far: 1.3 GiB memory in use, 3.4 GB disk on a test VM).

### Contributors / maintainers

- **Maintainer (`nolte`)** (ID `maintainer`) — _category_: contributor ·
  _surface_: the repository (`image/`, `build/`, `tests/`, `.github/`), the boot
  matrix, the specs under `spec/`, CI and the release workflows ·
  _expects_: a reproducible build, green CI and boot matrix before a release,
  spec-grounded decisions on base distribution and targets ·
  _track_: `developer-docs` · _status_: `confirmed` · _criticality_: secondary

### Governing parties

- **GDPR / data protection** — _category_: governing ·
  _surface_: personal data that Kamerplanter stores on the appliance, its
  backups, logs and secrets; the self-hoster is the controller ·
  _expects_: data kept on the operator's machine, backups that include the
  secrets needed to read them, no data leaving the device unasked ·
  _track_: `developer-docs` · _status_: `assumed` · _criticality_: secondary
  - Open questions: what the appliance itself has to document for the
    controller beyond the upstream privacy documentation.

- **Licences and trademarks** — _category_: governing ·
  _surface_: redistribution of the built image; the base distribution's
  trademark rules (Fedora requires its release and logo packages to be replaced
  in a modified build) and the licences of the packaged container images ·
  _expects_: an own `os-release` identity, licence and component lists with
  every release ·
  _track_: `developer-docs` · _status_: `assumed` · _criticality_: secondary

- **Terms of the hosting providers** — _category_: governing ·
  _surface_: the rules of Hetzner, OVHcloud and the large cloud providers on
  custom images and publicly reachable services ·
  _expects_: installation paths that stay within self-service, no shared or
  published images where a provider does not allow them ·
  _track_: `developer-docs` · _status_: `assumed` · _criticality_: secondary

### Indirect audiences

- **Kamerplanter users** — _category_: indirect ·
  _surface_: the web UI served by an appliance someone else runs ·
  _expects_ (without knowing): the service stays available across updates and
  reboots, no data is lost ·
  _track_: `user-docs` · _status_: `assumed` · _criticality_: peripheral
  - Open questions: none — their documentation lives upstream.

- **Upstream Kamerplanter project** — _category_: indirect ·
  _surface_: the container images and configuration the appliance packages;
  findings reported back (for example the ineffective ArangoDB health check and
  the secrets missing from the release Compose file) ·
  _expects_: images used unmodified and pinned by digest, problems reported
  upstream instead of patched around ·
  _track_: `developer-docs` · _status_: `assumed` · _criticality_: peripheral

## Open questions (cross-cutting)

- No audience maps to a separate end-user surface of the appliance besides the
  self-hoster; Kamerplanter users are served by the upstream documentation.

## Revisit triggers

Re-run `audience-identify revisit` when any of the following changes:

- A new delivery target becomes a reference target (for example a cloud
  provider or the Raspberry Pi).
- A managed or shared offering appears where someone runs appliances for others.
- The appliance gains its own provisioning interface (cloud-init, a setup page)
  or its own public API beyond the Kamerplanter ports.
- External contributors start submitting changes.
