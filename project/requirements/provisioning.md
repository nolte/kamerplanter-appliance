# Requirements — Configuration through provisioning data

<!--
Produced via the `requirements-elicit` skill, following
spec/project/requirements-elicitation/.
Do not record a requirement before declaring the bounded context below.
`c_d` is an uncertainty proxy (self-consistency-derived), not a calibrated
probability. A requirement is `confirmed` only after an explicit teach-back.
-->

Source: nolte/kamerplanter-appliance#17. Interview held 2026-11-14 in German with the maintainer (11 questions); quotes below are the maintainer's answers, translated where needed.

## Bounded context

- **What:** The appliance applies provisioning data at boot: cloud-init in the image reads NoCloud sources and the metadata servers of the hosted targets, so hostname, network, and SSH keys take effect; Kamerplanter settings and, optionally, secrets can be supplied before the first start. Without provisioning data the appliance behaves as today.
- **For whom:** `nolte/kamerplanter-infrastructure` (Terraform, which already passes a NoCloud drive on Proxmox VE); self-hosters on Proxmox VE, hosted servers, and mini PCs (NoCloud drive on a USB stick, seed URL).
- **Out of scope:** the Terraform side (`appliance_config` input); naming the data disk and its LUKS key from #15 (a separate channel, Q1); a secret rotation command on the appliance (configuration and rotation after provisioning belong to nolte/kamerplanter-infrastructure#8, Q3).

## Understanding KPI

- Thresholds: `τ_low = 0.4`, `τ_high = 0.8`, self-consistency `k = 2`, question budget = `15` (spec defaults)
- `U_gate = min_d c_d` over required dimensions = **0.8**
- Termination: `saturation` (11 of 15 questions; the final question was a full teach-back the maintainer confirmed: "das passt so")

### Gap matrix

| Dimension | Applicable | `c_d` | Uncertainty source | Evidence event |
|---|---|---|---|---|
| `functional` | yes | 0.85 | specification | Q4, Q8–Q10; teach-back Q11 |
| `non_functional` | yes | 0.8 | specification | Q2 (secret protection), Q6/Q7 (hardening); teach-back Q11 |
| `constraints` | yes | 0.8 | interpretation | issue body (bootc image, spec D4/D11/H6/H7); verified: cloud-init, afterburn, ignition not installed in `localhost/kamerplanter-appliance:poc` (`rpm -q`) |
| `domain_objects` | yes | 0.85 | interpretation | Q4 (configuration layer), Q10 (`kamerplanter:` key) |
| `actors` | yes | 0.85 | interpretation | Q1, Q2 (provisioner, Proxmox credentials), Q3 (Ansible role in infrastructure) |
| `acceptance_criteria` | yes | 0.8 | specification | issue list extended in teach-back Q11 |
| `edge_cases` | yes | 0.8 | specification | Q6/Q7 (every-boot vs hardening conflict resolved), no provisioning data (issue, Q11) |
| `scope_boundaries` | yes | 0.85 | specification | Q1 (separate from #15), Q3 (rotation in infrastructure#8) |

Self-consistency (`k = 2`) lowered `c_d` twice: the answer "c" to Q5 (pass all keys through) diverged from Q2 (no secrets via cloud-init), and Q4 (every boot) diverged from the hardening of Q6; both were resolved by explicit questions (Q6, Q7) instead of being assumed.

## Requirements

### Provisioning client

- **R1** — The system image SHALL contain cloud-init with its full module set enabled.
  - _dimension_: `functional` · _status_: `confirmed` · _source_: Q8 "b"
- **R2** — WHEN provisioning data is present, the appliance SHALL read it from the NoCloud datasource in all three forms: a drive labelled `CIDATA` (virtual drive or USB stick), a seed URL given on the kernel command line or in the SMBIOS serial number, and seed files on the disk (`/var/lib/cloud/seed/nocloud/`).
  - _dimension_: `functional` · _status_: `confirmed` · _source_: Q8 note "es sollte ebenfalls nocloud unterstützt werden"; Q9 "alle 3 bitte"
- **R3** — WHEN the appliance runs on a hosted target (Hetzner Cloud, OVHcloud), it SHALL read the provisioning data from that target's metadata service.
  - _dimension_: `functional` · _status_: `confirmed` (proposed as assumption from spec H6, confirmed in teach-back Q11) · _source_: Q11
- **R4** — WHEN provisioning data names a hostname, network configuration (e.g. static IPv4 address, gateway, DNS servers) or SSH keys, the appliance SHALL apply them at boot.
  - _dimension_: `functional` · _status_: `confirmed` · _source_: issue acceptance criteria; teach-back Q11
- **R5** — WHILE no provisioning data is present, the appliance SHALL come up through DHCP and complete its first-boot setup as before.
  - _dimension_: `functional` · _status_: `confirmed` · _source_: issue; teach-back Q11
- **R6** — The documentation SHALL warn that cloud-init changes outside the documented interface can interfere with updates and rollbacks.
  - _dimension_: `non_functional` · _status_: `confirmed` · _source_: Q8 option text; teach-back Q11

### Kamerplanter settings

- **R7** — The appliance SHALL accept Kamerplanter settings from a `kamerplanter:` → `settings:` map in the cloud-config (the documented interface), and SHALL also honour settings written by cloud-init `write_files` to the documented provisioning file.
  - _dimension_: `domain_objects` · _status_: `confirmed` · _source_: Q10 "c"
- **R8** — The appliance SHALL apply provisioned settings on every boot as their own configuration layer, ordered: image defaults, provisioning data, generated secrets, the user's file; a later layer wins.
  - _dimension_: `functional` · _status_: `confirmed` (layer order proposed, confirmed in Q11) · _source_: Q4 "c"
- **R9** — The appliance SHALL pass through every provisioned key; the configuration check SHALL validate provisioned values like those of the user's file, and an invalid value SHALL keep the services stopped with the same message.
  - _dimension_: `edge_cases` · _status_: `confirmed` (validation behaviour proposed, confirmed in Q11) · _source_: Q5 "c"; Q6 "i"

### Secrets

- **R10** — By default the appliance SHALL generate its secrets itself, as today.
  - _dimension_: `non_functional` · _status_: `confirmed` · _source_: Q2 "1 als Standard"
- **R11** — On Proxmox VE (and QEMU), the appliance SHALL accept secrets as systemd credentials.
  - _dimension_: `functional` · _status_: `confirmed` · _source_: Q2 "dazu 3 für Proxmox"
- **R12** — The appliance SHALL accept secrets from a `kamerplanter:` → `secrets:` map in the cloud-config, and SHALL take them over into `secrets.env` only on the first boot.
  - _dimension_: `functional` · _status_: `confirmed` · _source_: Q6 "i"; Q7 "a"
- **R13** — After taking over provisioned secrets, the appliance SHALL remove the copies cloud-init keeps under `/var/lib/cloud`, and SHALL restrict access to the metadata service to root; the documentation SHALL recommend detaching the NoCloud drive after the first boot.
  - _dimension_: `non_functional` · _status_: `confirmed` · _source_: Q6 "i" (hardening of option 4); Q7 "a"
- **R14** — The pin rules for `ERASURE_TOMBSTONE_SALT`, `FERNET_KEY` and `ARANGODB_PASSWORD` SHALL apply unchanged to provisioned secrets.
  - _dimension_: `constraints` · _status_: `confirmed` · _source_: teach-back Q11
- **R15** — The appliance SHALL NOT offer its own secret rotation command; later changes go through the user's file or the Ansible role of nolte/kamerplanter-infrastructure#8.
  - _dimension_: `scope_boundaries` · _status_: `confirmed` · _source_: Q3 "das passt so"
- **R16** — The naming of the data disk and its LUKS key (#15) SHALL NOT use this provisioning channel.
  - _dimension_: `scope_boundaries` · _status_: `confirmed` · _source_: Q1 "das bleiben getrennte wege"

### Specs, documentation and tests

- **R17** — `spec/distribution-requirements/` (D4, D11) and `spec/deployment-targets/` (H6) SHALL describe the interface, its lifecycle, and the secret policy.
  - _dimension_: `constraints` · _status_: `confirmed` (spec ownership proposed, confirmed in Q11) · _source_: Q11
- **R18** — The boot tests SHALL cover: a NoCloud drive applying hostname, SSH key and a static IPv4 address; no provisioning data (DHCP as before); a seed URL; `FRONTEND_URL` from provisioning data in effect at the first start of the services; a secret via cloud-init landing in `secrets.env` with the cached copies removed; a secret via a systemd credential.
  - _dimension_: `acceptance_criteria` · _status_: `confirmed` · _source_: issue acceptance criteria; teach-back Q11
- **R19** — The documentation SHALL describe the interface (`kamerplanter:` key and `write_files`), its lifecycle, the secret paths and their protection, and the hardening steps.
  - _dimension_: `acceptance_criteria` · _status_: `confirmed` · _source_: issue; teach-back Q11

## Surviving assumptions / open risks

- **Hosted datasources unverified:** whether cloud-init's Hetzner and OVH datasources work in the appliance as-is (OVH may expose an OpenStack-compatible service) is unverified; settled on a real target or a test double.
- **Every-boot layer vs cloud-init caching:** cloud-init processes user-data per instance; reading the `kamerplanter:` key on every boot (R8) while removing cached copies with secrets (R13) needs a design that re-reads or keeps only the non-secret part.
- **Metadata restriction (R13):** an nftables rule limited to root can break other consumers of the metadata service; to be checked in design.
- **Full cloud-init (R1) on an immutable system:** modules that install packages or write under `/usr` fail or have no lasting effect; documented as a warning (R6), not prevented.
- **Interaction with the image's own first-boot setup:** cloud-init and `kamerplanter-config.service` ordering at first boot must guarantee R8/R12 take effect before the services start.
- **Secrets in provisioning data at rest:** NoCloud drives and Proxmox snippet storage keep secrets in plain text until detached or deleted; documented (R13, R19), not controlled by the appliance.
