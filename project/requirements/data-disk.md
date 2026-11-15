# Requirements — Optional separate data disk

<!--
Produced via the `requirements-elicit` skill, following
spec/project/requirements-elicitation/.
Do not record a requirement before declaring the bounded context below.
`c_d` is an uncertainty proxy (self-consistency-derived), not a calibrated
probability. A requirement is `confirmed` only after an explicit teach-back.
-->

Source: nolte/kamerplanter-appliance#15. Interview held 2026-11-14 in German with the maintainer (14 questions); quotes below are the maintainer's answers, translated where needed.

## Bounded context

- **What:** The appliance can keep its persistent data and configuration on an optional local data disk, separate from the system disk, so that the life cycle of the system (VM or system disk) is independent of the life cycle of the data. Without a data disk the appliance behaves as before.
- **For whom:** self-hosters who recreate, move, resize, or replace their appliance (new release, other hardware or hypervisor) and keep their data; `nolte/kamerplanter-infrastructure`, which recreates VMs from a release image and attaches a disk with its own life cycle; self-hosters on mini PCs with a second drive or USB storage.
- **Media in scope:** a second disk of a VM, a second internal drive, a USB disk or USB stick.
- **Out of scope:** NFS and other network file systems (a later, separate topic); the Terraform module in `kamerplanter-infrastructure`; Kamerplanter's own database migration rules; backups to external locations beyond the pre-update backup; key management beyond accepting a provisioned key.

## Understanding KPI

- Thresholds: `τ_low = 0.4`, `τ_high = 0.8`, self-consistency `k = 2`, question budget = `15` (spec defaults; budget is an engineering value for an issue of this size)
- `U_gate = min_d c_d` over required dimensions = **0.8**
- Termination: `saturation` (14 of 15 questions; the final question was a full teach-back the maintainer confirmed: "das ist ok!")

### Gap matrix

| Dimension | Applicable | `c_d` | Uncertainty source | Evidence event |
|---|---|---|---|---|
| `functional` | yes | 0.85 | specification | answers Q3–Q13; full teach-back Q14 confirmed |
| `non_functional` | yes | 0.8 | specification | Q12 (optional encryption), Q7 (no silent second data state); no performance requirement stated beyond the boot-test budgets (teach-back Q14) |
| `constraints` | yes | 0.8 | interpretation | issue body (bootc, `/etc` handling, labels instead of device names); Q3 (no databases on NFS); feasibility of moving `/etc/kamerplanter/*` under bootc is a design risk, not a requirement ambiguity |
| `domain_objects` | yes | 0.85 | interpretation | Q9/Q10 (data disk vs backup disk), Q8 (release marker on the disk), teach-back Q14 |
| `actors` | yes | 0.85 | interpretation | Q1/Q2 (self-hoster, infrastructure repo, mini PCs), Q13 (provisioner supplies keys) |
| `acceptance_criteria` | yes | 0.8 | specification | issue acceptance list extended in teach-back Q14 |
| `edge_cases` | yes | 0.85 | specification | Q5 (migration), Q6 (fallback copy), Q7 (missing disk), Q8 (downgrade), Q11 (backup disk missing/full) |
| `scope_boundaries` | yes | 0.9 | specification | Q1–Q3; NFS excluded in Q3 ("c") |

Self-consistency (`k = 2`) lowered `c_d` before Q3, Q4 and Q10: for "NFS", "formatting a blank disk" and "dedicated disk" two independent readings diverged, so each was asked as options instead of assumed.

## Requirements

### Setup and detection

- **R1** — WHEN a disk is named for Kamerplanter data in the appliance configuration or by the provisioner at first start, the appliance SHALL format it and give it the file system label `kp-data`; it SHALL NOT format any disk that is not named this way.
  - _dimension_: `functional` · _status_: `confirmed` · _source_: Q4 "c"
- **R2** — WHEN the appliance boots, it SHALL detect the data disk by the label `kp-data`, not by device name, and mount it before any Kamerplanter service starts.
  - _dimension_: `functional` · _status_: `confirmed` · _source_: issue body; teach-back Q14
- **R3** — The data disk SHALL be a local block device: a second VM disk, a second internal drive, a USB disk, or a USB stick. NFS and other network file systems are not supported as a data location.
  - _dimension_: `scope_boundaries` · _status_: `confirmed` · _source_: Q2 "auch für mini-pcs mit zweiter platte … usbsticks"; Q3 "c"
- **R4** — WHILE no data disk is set up, the appliance SHALL behave as it does without this feature.
  - _dimension_: `functional` · _status_: `confirmed` · _source_: issue acceptance criteria; teach-back Q14

### Content

- **R5** — WHILE a data disk is mounted, the appliance SHALL keep on it the ArangoDB and Valkey data, `/etc/kamerplanter/kamerplanter.env`, `/etc/kamerplanter/secrets.env`, and the pins in `/var/lib/kamerplanter/pinned/`.
  - _dimension_: `domain_objects` · _status_: `confirmed` · _source_: issue body; teach-back Q14
- **R6** — The data disk SHALL record the highest appliance release that has used it.
  - _dimension_: `domain_objects` · _status_: `confirmed` · _source_: Q8 "b"; teach-back Q14
- **R7** — The update state (record, list of releases never applied again, last good version) SHALL stay with the system, not on the data disk.
  - _dimension_: `domain_objects` · _status_: `confirmed` · _source_: proposed as assumption in Q14, confirmed by teach-back

### Life cycle

- **R8** — WHEN a freshly installed appliance is given a data disk named explicitly (as in R1), it SHALL use the configuration, secrets and data on it, bind to the disk's UUID, and SHALL NOT generate new secrets for keys the disk holds; it SHALL NOT adopt an unnamed disk only because it carries the label `kp-data`.
  - _dimension_: `functional` · _status_: `confirmed` · _source_: issue body; Q1 "die flexibilität sind die hauptgründe"
- **R9** — WHEN a data disk is named on an appliance that already holds data on its system disk, the appliance SHALL stop the services, move data, configuration, secrets and pins onto the data disk, and continue from the data disk.
  - _dimension_: `functional` · _status_: `confirmed` · _source_: Q5 "a"
- **R10** — After such a move, the appliance SHALL keep the previous copy on the system disk until the appliance has started healthy from the data disk and `UPDATE_BACKUP_KEEP_DAYS` have passed; IF the start from the data disk fails, THEN it SHALL return to the previous copy.
  - _dimension_: `edge_cases` · _status_: `confirmed` · _source_: Q6 "a"
- **R11** — IF a data disk is set up but missing at boot, THEN the appliance SHALL keep the Kamerplanter services stopped and report that the disk `kp-data` is missing; it SHALL start them once the disk is back (next boot or `systemctl restart kamerplanter.target`).
  - _dimension_: `edge_cases` · _status_: `confirmed` · _source_: Q7 "a"
- **R12** — IF the data disk was used by a release newer than the running one, THEN the appliance SHALL keep the services stopped and name both releases; it SHALL offer a command with which the self-hoster deliberately overrides this.
  - _dimension_: `edge_cases` · _status_: `confirmed` · _source_: Q8 "b"

### Encryption

- **R13** — The data disk MAY be encrypted with LUKS; encryption SHALL be optional.
  - _dimension_: `non_functional` · _status_: `confirmed` · _source_: Q12 "b"
- **R14** — The key of an encrypted data disk SHALL always come from the provisioner, as a systemd credential or a dedicated file on the system disk, never in the user file; the appliance SHALL NOT generate it. The appliance SHALL keep a provisioned key on the system disk or in the TPM to unlock the disk on later boots.
  - _dimension_: `actors` · _status_: `confirmed` (local keeping: assumption confirmed by teach-back Q14) · _source_: Q13 "b"

### Pre-update backup (spec/update-and-rollback/ D2–D5)

- **R15** — A separate backup disk (label `kp-backup`) MAY be set up the same way as the data disk (R1).
  - _dimension_: `domain_objects` · _status_: `confirmed` · _source_: Q10 "b"; setup mechanism proposed as assumption, confirmed in Q14
- **R16** — WHEN the appliance takes the backup before a new release first starts, it SHALL write it to the backup disk if one is set up, otherwise to the data disk if one is set up, otherwise to the system disk.
  - _dimension_: `functional` · _status_: `confirmed` · _source_: Q9 "c, im zweifel auf einem dedizierten datenträger"; Q10 "b"
- **R17** — IF the preferred backup location is missing or lacks space, THEN the appliance SHALL fall back to the next location in the order of R16 and record that it did; IF no location has space, THEN it SHALL postpone the update as today (D5).
  - _dimension_: `edge_cases` · _status_: `confirmed` (last clause: assumption confirmed by teach-back Q14) · _source_: Q11 "b"

### Documentation and tests

- **R18** — The boot tests SHALL cover at least: no data disk; with a data disk; replacing the VM with one from the same release and attaching the same data disk (data, logins and encrypted fields kept); moving a running appliance onto a data disk; a missing data disk; a refused downgrade.
  - _dimension_: `acceptance_criteria` · _status_: `confirmed` · _source_: issue acceptance criteria; teach-back Q14
- **R19** — The documentation SHALL describe setting up the data and backup disks, what they contain, the backup implications, and the risk of removable media (a stolen unencrypted stick carries the secrets and the database).
  - _dimension_: `acceptance_criteria` · _status_: `confirmed` · _source_: issue acceptance criteria; Q12 context; teach-back Q14

## Revisions

- **2026-11-14, labels:** ext4 file system labels hold at most 16 characters (xfs: 12); `mkfs.ext4` silently truncated `kamerplanter-data` to `kamerplanter-dat` in the P1 spike. The maintainer chose `kp-data` and `kp-backup` (fit ext4 and xfs). R1, R2, R11 and R15 updated; status stays `confirmed` (operator decision).

- **2026-11-14, security review (security-requirements-reviewer on the P2 specs):** the maintainer decided (1) a fresh appliance adopts only an explicitly named data disk and binds it to its UUID (R8 revised; label-only adoption let a prepared stick inject secrets and data); (2) the LUKS key comes only as a credential or a system-side file, never in the user file, which moves onto the disk (R14 revised); (3) with an encrypted data disk, the pre-update backup goes only to an equally protected location (R20 added). Status `confirmed` (operator decisions).

- **R20** — WHILE the data disk is encrypted, the appliance SHALL write the pre-update backup only to an equally protected location: an encrypted backup disk, the encrypted data disk, or the system disk when the key is kept there; otherwise it SHALL postpone the update.
  - _dimension_: `non_functional` · _status_: `confirmed` · _source_: security review decision 2026-11-14 ("Nur gleich geschützt")

- **2026-11-15, security review (P11, before the PR):** the maintainer decided that disks are named, and a format forced, only from the system side: a systemd credential or the naming file `/var/lib/kamerplanter/disks/naming.env` on the system disk (`disks name`). The user file names a disk only while no data disk is set up (it lies on the system disk then); once one is, its `DATA_DISK`, `BACKUP_DISK` and `*_FORCE` are ignored with a message, since the file lies on a disk that may have been changed elsewhere. "In the appliance configuration" in R1 reads accordingly. `UPDATE_BACKUP_KEEP_DAYS` counts as at least 3 days.

## Surviving assumptions / open risks

- **Design risk — `/etc` under bootc:** whether `kamerplanter.env` and `secrets.env` can move to the data disk by bind mount or symlink while `/etc` is merged by ostree on updates is unverified (issue open question). Settled by a prototype; the requirement (R5) stands either way.
- **Design risk — database files on USB sticks:** wear and power-loss behaviour of cheap sticks under RocksDB is not assessed; R19 documents the risk, no further requirement was set.
- **Design risk — file system and formatting tool:** not discussed; an engineering choice (e.g. ext4/xfs) for the design.
- **Interaction with A4 (forward-only):** R12 extends the on-device rule of spec/update-and-rollback/ A4 across disk moves; spec/update-and-rollback/, spec/distribution-requirements/ (state separation) and spec/deployment-targets/ (disk layout per target) need updating.
- **Missing-disk and override commands:** their names and the exact status surface (console issue, `kamerplanter-update status` or a new command) are left to design.
- **Out-of-scope follow-ups:** NFS as data location (Q3), and `kamerplanter-infrastructure` adding an optional data disk to `proxmox-appliance-vm` (issue follow-up).
