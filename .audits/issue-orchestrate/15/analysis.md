---
artifact-type: issue-orchestration-analysis
repo: "nolte/kamerplanter-appliance"
issue: "15"
classification: "feature-request"
secondary-classes: ["spec-change", "security"]
route: "direct"
status: approved
created: "2026-11-14"
---

# Issue Orchestration — Pre-analysis

<!-- Run-scoped artifact: committed on feat/data-disk, then removed with a fix-forward `git rm` before the PR merges, per spec/project/issue-orchestration/ §Pre-analysis artifact lifecycle. Anything worth keeping after the merge goes into the PR's Risk / rollout notes or the issue comment first. -->

Drafted by `nolte-engineering:implementation-plan-author` on 2026-11-14 and written to disk by the orchestrator (the agent may not write report files).

## Issue metadata

- **Repository**: nolte/kamerplanter-appliance
- **Issue**: #15 — feat: keep persistent data on an optional separate data disk
- **URL**: https://github.com/nolte/kamerplanter-appliance/issues/15
- **Labels**: enhancement
- **Author / trust**: `nolte` (repository owner, trusted author per `spec/claude/trusted-author-injection-guard/`). The issue has 0 comments, so no untrusted text enters the plan.
- **Linked items**: none linked formally. Builds on PR #16 (update and rollback, merged 2026-11-14, contained in base `e3cadc8`). Follow-up in `nolte/kamerplanter-infrastructure` (`proxmox-appliance-vm` optional data disk) is out of scope.
- **Grounded input**: `project/requirements/data-disk.md` — R1–R19, all `confirmed`, `U_gate = 0.8 ≥ τ_high = 0.8`, terminated by saturation after a teach-back. Every package traces to these R-ids; the issue prose is context only.
- **Prior art checked**: `project/` holds only `requirements/data-disk.md` (no `project/features/`, no `project/roadmap.md`). The only open PR is #18 (Renovate base-image digest), which is unrelated. No merged fix exists.
- **Working copy**: `/home/nolte/repos/.worktrees/kamerplanter-appliance/data-disk`, branch `feat/data-disk`, base `origin/develop` `e3cadc8281f467e9bbfd836f13ea893cef30b5af`.

## Classification

- **Primary class**: feature-request
- **Secondary class(es)**: spec-change, security
- **Rationale**: This is a new optional storage capability (feature). It changes three specs (`spec/update-and-rollback/`, `spec/distribution-requirements/`, `spec/deployment-targets/`) and introduces destructive formatting, LUKS key handling, and secrets on removable media (security). Decided by the operator; not reopened.
- **Asserted cause verified**: The issue says "All Kamerplanter state lives on the system disk … Nothing mounts a second disk." **Confirmed** at `e3cadc8`:
  - `grep -rniE 'mount|kp-data|cryptsetup|luks|fstab' image/ build/ tests/` returns nothing. No `*.mount`, `crypttab` or `fstab` exists under `image/`.
  - The disk image is one disk with one ext4 root: `build/disk.sh:76` (`bootc install to-disk … --filesystem ext4 --wipe`).
  - Database state is in Podman named volumes under `/var`: `image/rootfs/usr/share/containers/systemd/arangodb.volume:2` and `valkey.volume:2`, used by `kamerplanter-arangodb.container:8` and `kamerplanter-valkey.container:8`. `image/rootfs/usr/bin/kamerplanter-update:36` hard-codes `volumes=/var/lib/containers/storage/volumes`.
  - Configuration and pins are on the system disk: `image/rootfs/usr/libexec/kamerplanter/configure:22-24`.

## Scope

- **In scope** (R1–R19):
  - Opt-in setup of a local data disk (label `kp-data`) and a backup disk (label `kp-backup`). Only an explicitly named disk is formatted. The disk is found by its label and mounted before any Kamerplanter unit starts (R1–R4, R15).
  - Placing the ArangoDB and Valkey data, `kamerplanter.env`, `secrets.env` and the pins on the data disk (R5). A fresh appliance adopts an existing disk without generating secrets (R8).
  - Moving an existing appliance onto a newly named data disk, keeping the system-disk copy as a fallback (R9, R10).
  - What happens when the disk is missing (R11). A release marker on the disk, refusal of a downgrade, and a deliberate override command (R6, R12). The update state stays with the system (R7).
  - Optional LUKS encryption with a key the provisioner supplies, kept on the system disk or in the TPM (R13, R14).
  - The pre-update backup goes to the backup disk, else the data disk, else the system disk. A fallback to the next location is recorded. When no location has space, the update is postponed as today (R16, R17).
  - Spec updates (en canonical + de), boot tests (R18), self-hoster documentation in en + de (R19), and the README wording about the "data partition".
- **Out of scope**:
  - NFS and any other network file system (R3; operator decision). This is a later, separate topic.
  - The Terraform module in `nolte/kamerplanter-infrastructure` (follow-up issue there).
  - Kamerplanter's own database migration rules (`nolte/kamerplanter`).
  - Backups to external locations beyond the pre-update backup.
  - Key management beyond accepting a provisioned key: no key generation, rotation or escrow.
  - Assessing USB-stick wear under RocksDB. It is documented as a risk only, as the requirements' open-risk section says.

## Route

- **Decision**: direct — **one pull request** from `feat/data-disk`.
- **Rationale**:
  - The work has one coherent goal outcome: the system's life cycle becomes independent of the data's life cycle.
  - No roadmap item is created or retargeted (no `project/roadmap.md` exists), and there is one feature branch.
  - The size (11 packages across specs, image units, update tool, tests and docs) would normally suggest several PR strands. **The operator overrode the multi-strand heuristic on 2026-11-14** ("ein großer pr sollte reichen").
  - Why the override is sound: the packages are tightly coupled. Mount ordering, configuration paths, update-tool backup paths and boot tests all change the same boot sequence. An intermediate PR that mounts a disk without moving the data, or moves data without the missing-disk guard, would ship an unsafe half-state.
  - The packages are therefore **ordered commits within that one PR**, not separate PRs.
- **Pipeline hand-off**: not applicable.

## Work packages

**How the specialists were resolved:** on 2026-11-14 by listing `~/.claude/plugins/marketplaces/nolte-shared/` (`agents/`, `skills/`, `plugins/nolte-engineering/agents/`) and reading each candidate's `description`. `security-review` is the Claude Code built-in diff-scoped review skill; it is not in the plugin catalog.

**Repository conventions every package follows** (detected, not assumed):

- Bash scripts use `set -euo pipefail` and `umask 077`; config files are parsed by the shared `image/rootfs/usr/lib/kamerplanter/env.sh`.
- systemd units live in `image/rootfs/usr/lib/systemd/system/`; Quadlet units in `image/rootfs/usr/share/containers/systemd/`.
- Executables are made executable and units enabled in `image/Containerfile:33-41`.
- Build gates: `podman-system-generator --dryrun` (`Containerfile:53`) and `bootc container lint` (`:55`).
- `task lint` runs pre-commit, including shellcheck and yamllint.
- Boot tests run through `build/in-tools.sh` (`task test:boot`, `task test:update`).
- Specs live in `spec/<topic>/en.md` (canonical) plus `de.md`.
- Docs live in `docs/en|de/` with front matter `audience`/`content_mode`/`track`/`last_updated`. Nav is in `mkdocs.yml:130-139`, with `nav_translations` at `:72-79`.

### P1 — Feasibility spike: configuration on the data disk under bootc/ostree, and the base-image toolset

- **Problem statement**: Before any package builds on it, settle how `/etc/kamerplanter/kamerplanter.env` and `secrets.env` can live on the data disk, given that ostree merges `/etc` per deployment on every update and rollback. Also settle which needed tools the base image ships.
- **Questions to settle** (each answered with a command and its output, recorded under Findings):
  1. **`/etc` mechanism.** Compare (a) bind-mount `<disk>/etc` onto `/etc/kamerplanter`; (b) symlink it, as a directory or per file; (c) move the authoritative location to a path on the disk and change the readers (`configure:22-23`, `kamerplanter-update:40`, `kamerplanter-update-window:12`), keeping `/etc/kamerplanter` only as the fallback for R4. For each option, test after `bootc upgrade` to the `next` test variant plus a reboot, and after `bootc rollback`: do the readers still see the data-disk files? Does the system disk now hold a copy of secrets written after the move (inspect `/ostree/deploy/*/deploy/*/etc/kamerplanter/`)? Such a copy would be a silent second data state and would leave secrets on the system disk.
  2. **Early readers.** The window generator reads the user file at generator time, before any mount (`kamerplanter-update-window:12`). Which option keeps `UPDATE_WINDOW` from a data-disk user file in effect (a `daemon-reload` after the mount, or a runtime drop-in written after the mount)?
  3. **Volume placement.** Bind-mount `<disk>/volumes/{arangodb_data,valkey_data}` over `/var/lib/containers/storage/volumes/<name>` (keeps the paths in `kamerplanter-update:36-38`, `tests/boot/update.sh:31` and `tests/boot/variants/Containerfile` valid), or a Quadlet `.volume` with `Type=bind`/`Device=`. Check whether Podman accepts a fresh VM attaching an existing volume directory.
  4. **Toolset in `quay.io/fedora/fedora-bootc:46`** (`image/Containerfile:7`): `mkfs.ext4`/`mkfs.xfs`, `cryptsetup`, `systemd-cryptsetup`, `systemd-cryptenroll`, by-label udev links for a LUKS2 header label, TPM2 support.
  5. **File system choice.** ext4 or xfs? Default recommendation ext4, matching `build/disk.sh:76`.
- **Acceptance criteria**:
  - Run a QEMU VM from the current disk image with a second qcow2 attached. With the chosen mechanism, `configure` reads `kamerplanter.env` and `secrets.env` from the data disk, and still does so after an update to `next` and after a rollback.
  - The check from question 1 shows no secrets copy on the system disk caused by the merge. If a copy is unavoidable, the finding names it and the decision accounts for it.
  - With `UPDATE_WINDOW` set only in the data-disk user file, `systemctl show kamerplanter-update-apply.timer -p TimersCalendar` shows that value after boot.
  - Questions 3–5 each have a recorded decision with its evidence.
  - No committed code. The result is a decision record (Findings), carried into P2 as "Established".
- **Touched files / artifacts**: this artifact (Findings); a scratch prototype only.
- **Specialist**: no matching specialised agent — generalist remediation (bootc/ostree prototyping on QEMU via `build/in-tools.sh`).
- **Depends on**: none.
- **Traces to**: R5 (design risk "`/etc` under bootc"), R13/R14 (toolset), open risk "file system and formatting tool".

### P2 — Specs: data disk, backup disk, state separation, downgrade guard (en + de)

- **Problem statement**: The three specs that own state separation, disk layout and update behaviour have no notion of a separate data disk. R1–R19 need a normative home before implementation starts.
- **Acceptance criteria**:
  - `spec/distribution-requirements/en.md` §E (lines 108-114) gains requirements for the optional data disk (label detection, opt-in formatting, local block devices only, behaviour without a disk, a missing disk, optional LUKS with a provisioned key); E2 lists the data-disk locations among the persistent set; E5 says where the secrets live with and without a data disk; the `/etc`-under-bootc question moves to Context as "Established", with P1's evidence.
  - `spec/deployment-targets/en.md` D3 (line 91) becomes a disk layout per target (VM second disk, mini-PC second drive, USB disk or stick), states the removable-media risk and names NFS as a non-goal.
  - `spec/update-and-rollback/en.md`: D2/D4/D5 (lines 81-84) state the backup-location order and that a fallback is recorded (R16, R17); A4 (line 52) is extended across disk moves through the release marker and the override (R6, R12); R7 (update state stays with the system) is stated; the open question at line 157 is updated.
  - Every R1–R19 maps to at least one spec requirement id; the PR body carries that table.
  - The de versions match, and the `spec` skill's drift check is clean.
  - Recommended: `nolte-shared:spec-readiness-reviewer` finds no contradiction, and `nolte-shared:security-requirements-reviewer` finds no missing control for LUKS and removable media; otherwise their findings are triaged.
- **Touched files / artifacts**: `spec/distribution-requirements/{en,de}.md`; `spec/deployment-targets/{en,de}.md`; `spec/update-and-rollback/{en,de}.md`; `spec/README.md` (index, if regenerated).
- **Specialist**: `nolte-shared:spec` (skill). Review by `nolte-shared:spec-readiness-reviewer` and `nolte-shared:security-requirements-reviewer`.
- **Depends on**: P1.
- **Traces to**: R1–R19; open risk "Interaction with A4".

### P3 — Data-disk service: naming, safe formatting, detection by label, mount before services, stop on missing disk

- **Problem statement**: Nothing detects, prepares or mounts a second disk, and nothing stops the services when a configured disk is absent.
- **Acceptance criteria**:
  - **No disk (R4):** with no disk named and none labelled, the boot is unchanged; existing `tests/boot/run.sh` runs and `tests/boot/update.sh` pass unchanged.
  - **Named blank disk (R1, R2):** a blank disk named through the configuration or a provisioner credential at first start is formatted with label `kp-data` and mounted before `kamerplanter-config.service` starts (ordering checked, `findmnt`).
  - **Unnamed blank disk (R1):** never formatted; `blkid` shows no signature.
  - **Label, not device name (R2):** the same disk mounts when attached as virtio-blk and as virtio-scsi.
  - **Disk set up but missing (R11):** every `kamerplanter-*` container unit stays inactive; no `secrets.env` is created and no secret generated on the system disk (`configure:74-100` never runs against an unmounted location); the console issue and unit status name `kp-data`; after reattaching the disk, `systemctl restart kamerplanter.target` or a reboot starts the services.
  - **Local disks only (R3):** a network file system is refused with a message.
  - **System-side record:** the fact that a disk is set up is recorded on the system disk, so R11 can tell "never set up" from "missing".
  - `task image:build` and `task lint` pass.
- **Touched files / artifacts**: new `image/rootfs/usr/libexec/kamerplanter/data-disk` (name up to the implementer); new `image/rootfs/usr/lib/systemd/system/kp-data.service` (plus a `.mount` unit if P1 chooses one); `image/rootfs/usr/share/containers/systemd/kamerplanter-.container.d/10-kamerplanter.conf:14-15`; `kamerplanter-config.service`, `kamerplanter-update-guard.service:6`, `kamerplanter.target`; `image/rootfs/usr/share/kamerplanter/kamerplanter.env` (naming setting); `image/Containerfile:33-36`; `kamerplanter-update:134-150` (`write_issue`) or a separate `/run/issue.d` snippet.
- **Specialist**: `nolte-engineering:fullstack-developer`.
- **Depends on**: P1, P2.
- **Traces to**: R1, R2, R3, R4, R11.

### P4 — Content on the data disk; adoption by a fresh appliance

- **Problem statement**: Even with a disk mounted, the volumes, user configuration, secrets and pins still resolve to the system disk.
- **Acceptance criteria**:
  - **Placement (R5):** with a data disk, `findmnt -T` and `stat` show `arangodb_data`, `valkey_data`, the user file, `secrets.env` and every pin on the data disk.
  - **Adoption (R8):** a fresh overlay of the same image with an existing disk attached keeps the `secrets.env` sha256, generates no secret (`configure:89-100`), passes the pin check (`configure:131-136`), and previous logins and encrypted fields work.
  - **Readers agree:** `configure` (`:22-24`), `kamerplanter-update` (`:36`, `:40`) and the window generator (`:12`) all use the same locations, and `UPDATE_WINDOW` from the disk file is in effect.
  - **No disk (R4):** paths stay unchanged.
  - **R7:** `/var/lib/kamerplanter/update/` stays on the system disk.
- **Touched files / artifacts**: `image/rootfs/usr/libexec/kamerplanter/configure`; `image/rootfs/usr/lib/kamerplanter/env.sh` (only if a shared path helper is added); `image/rootfs/usr/bin/kamerplanter-update`; `image/rootfs/usr/lib/systemd/system-generators/kamerplanter-update-window`; `arangodb.volume` and `valkey.volume` (if P1 chooses bind volumes); `image/rootfs/etc/kamerplanter/kamerplanter.env` (comment lines 3 and 14); P3's script.
- **Specialist**: `nolte-engineering:fullstack-developer`.
- **Depends on**: P3.
- **Traces to**: R5, R7, R8.

### P5 — Moving a running appliance onto a newly named data disk, with fallback copy

- **Problem statement**: An appliance that already holds data on its system disk needs a safe, recoverable, one-time move onto a newly named data disk.
- **Acceptance criteria**:
  - **Move (R9):** naming a disk on an appliance that holds data, then restarting the target or rebooting, stops the services, copies volumes, user file, secrets and pins to the disk, and brings the services up from the disk with the same data, logins and encrypted fields.
  - **Keep the old copy (R10):** the system-disk copy stays until the appliance has started healthy from the disk **and** `UPDATE_BACKUP_KEEP_DAYS` have passed; it is then deleted, and the deletion is recorded.
  - **Failed start (R10):** if the start from the disk is not healthy, the appliance returns to the system copy and records why. Proposed default for "healthy": `check_health` (`kamerplanter-update:427-446`) within `UPDATE_HEALTH_TIMEOUT`.
  - **Hard reset during the copy:** either the old or the completed new state is in use, never a mix; the system copy stays authoritative until the move is recorded complete.
  - The move is recorded system-side (`log.jsonl` or equivalent), readable through a documented command.
- **Touched files / artifacts**: P3's script and unit; `kamerplanter-update` (reuses `copy_volumes` `:124-132`, `check_health`, `cleanup` `:450-460`, `log` `:58-66`).
- **Specialist**: `nolte-engineering:fullstack-developer`.
- **Depends on**: P4.
- **Traces to**: R9, R10.

### P6 — Release marker, downgrade refusal, deliberate override command

- **Problem statement**: Reusing a data disk with an older release would run that release on data a newer Kamerplanter has already migrated, and today the appliance cannot detect this.
- **Acceptance criteria**:
  - **Marker (R6):** every release that starts the services on a disk raises the disk's marker to its version when higher; the marker holds the highest release that has used the disk.
  - **Refusal (R12):** a disk marked by a newer release keeps all `kamerplanter-*` container units inactive; the message names **both** releases, on the console and in the unit status.
  - **Override (R12):** one documented command overrides the refusal deliberately; it is recorded system-side, and the services then start.
  - **Comparison:** uses the same `release_version`/`forward` logic as the update tool (`kamerplanter-update:84-98`); the rule for development builds is stated in the spec and tested.
  - **R7:** the marker is on the disk; none of the update state moves there.
- **Touched files / artifacts**: P3's script; `kamerplanter-update` (subcommand or helper, usage text at `:4-31`, `cmd_status` at `:165-200`).
- **Specialist**: `nolte-engineering:fullstack-developer`.
- **Depends on**: P3.
- **Traces to**: R6, R7, R12.

### P7 — Optional LUKS encryption with a provisioner-supplied key (security-sensitive)

- **Problem statement**: A data disk on removable media carries the secrets and the database, so the self-hoster must be able to encrypt it with a key the provisioner supplies.
- **Acceptance criteria**:
  - **No key (R13):** the disk is set up unencrypted.
  - **Key supplied (R13, R14):** with a key from the configuration or a systemd credential, a named blank disk is formatted as LUKS2; its header label is found at boot, the disk is opened, and the file system inside is labelled `kp-data`. The appliance never generates a key.
  - **Key storage (R14):** the key is kept on the system disk (mode 0600, owned by root) or enrolled in the TPM, and unlocks the disk on later boots without user action.
  - **Key never leaks:** it is never written to the data disk, the journal, `/run/issue.d`, the `status` output or `log.jsonl`.
  - **Wrong or missing key:** the services stay stopped, with a message that does not contain the key.
  - **Fresh appliance (R8 + R14):** it opens an existing encrypted disk once the provisioner supplies the key again.
  - P11 passes with no open Critical or High finding.
- **Touched files / artifacts**: P3's script and unit; possibly `image/rootfs/etc/crypttab` or `systemd-cryptsetup` input (per P1); `image/Containerfile`; `image/rootfs/usr/share/kamerplanter/kamerplanter.env` (setting name only).
- **Specialist**: `nolte-engineering:fullstack-developer`. Review by `nolte-engineering:code-security-reviewer` plus the built-in `security-review` (P11).
- **Depends on**: P3 (and P1 question 4).
- **Traces to**: R13, R14.

### P8 — Backup disk and backup-location order

- **Problem statement**: The pre-update backup always goes to `/var/lib/kamerplanter/update/backup/` on the system disk, and the space check looks only at `/var`.
- **Acceptance criteria**:
  - **Backup disk (R15):** a disk named for backups is set up and detected like the data disk, with label `kp-backup`.
  - **Order (R16):** the guard's backup (`kamerplanter-update:372-394`) goes to the backup disk, else the data disk, else the system disk.
  - **Fallback (R17, D5):** if the preferred location is missing or short of space, the next location is used (space checked by `space_ok`, today hard-coded to `/var` at `:114-119`); `log.jsonl` records which location was used and why; if no location has space, behaviour is as today (`:275-278`, `:380-391`).
  - **Finding the backup:** restore (`:357-363`), the manual rollback check (`:312-313`) and `cleanup` (`:450-460`) find the backup wherever it was written; the location is recorded system-side (R7).
  - **No extra disks:** the existing `tests/boot/update.sh` steps pass.
- **Touched files / artifacts**: `kamerplanter-update`; P3's script; `kamerplanter-update-guard.service` (ordering).
- **Specialist**: `nolte-engineering:fullstack-developer`.
- **Depends on**: P3, P4.
- **Traces to**: R15, R16, R17, R7.

### P9 — Boot tests with a second disk (QEMU)

- **Problem statement**: The boot matrix attaches exactly one disk (`tests/boot/run.sh:45`, `start_vm` at `:37-65`), so it cannot exercise any data-disk case.
- **Acceptance criteria**:
  - `start_vm` (or a wrapper) can attach extra qcow2 disks and extra SMBIOS credentials, as `run.sh:44` already does for the SSH key; existing runs are unchanged.
  - New runs record PASS or FAIL in `results.tsv` and cover R18: (1) no data disk (existing runs); (2) with a data disk, using P4's checks; (3) a fresh overlay of the same release with the same disk attached, keeping data, logins and encrypted fields (API login before and after; a `FERNET_KEY`-encrypted value still readable); (4) moving a running appliance onto a newly named disk (P5); (5) a missing disk: services stopped, message names `kp-data`, services start after reattaching; (6) a refused downgrade, then the override command starts the services.
  - Recommended extra cases: a LUKS disk with a key from a credential, and the backup-disk fallback.
  - `tests/boot/update.sh:31` (`VOLUME`) and the `broken` variant in `tests/boot/variants/Containerfile` stay consistent with P1/P4.
  - `task test:boot`, `task test:update` and `task lint` pass.
- **Touched files / artifacts**: `tests/boot/run.sh`; possibly a new `tests/boot/data-disk.sh` that sources `run.sh` as `update.sh` does (`run.sh:230-231`); `tests/boot/update.sh`; `tests/boot/variants/Containerfile`; `Taskfile.yml`; `build/tools.Containerfile` (only if `swtpm` is added).
- **Specialist**: no matching specialised agent — generalist remediation. The catalog's test generators target application test tiers, not QEMU boot tests of an OS image.
- **Depends on**: P3, P4, P5, P6, P7, P8.
- **Traces to**: R18 (and verifies R1–R12, R14, R16, R17).

### P10 — Self-hoster documentation (en + de) and README

- **Problem statement**: The docs place the data in `/etc/kamerplanter/` and `/var/lib/kamerplanter/update/backup/` on the single disk (`docs/en/getting-started/updates.md:16`, `docs/en/references/configuration.md:63-66`). The README describes a "data partition" (`README.md:65`, `:75`, `:96`).
- **Acceptance criteria**:
  - **New page, en + de (R19)** explaining: setting up the data and backup disks (naming, formatting, labels, provisioner credential); what each disk contains; behaviour without a disk and with a missing disk; the downgrade refusal and its override; moving an existing appliance; optional encryption with a provisioned key; the removable-media risk (a stolen unencrypted stick carries the secrets and the database; USB-stick wear).
  - **Existing pages:** `updates.md` (en + de) states where the backup goes and the fallback order; `configuration.md` (en + de) names the new settings and updates the "Backups" warning.
  - **Site:** the page is registered in the nav (`mkdocs.yml:130-139`) and `nav_translations` (`:72-79`) with the usual front matter; `mkdocs build --strict` passes.
  - README lines 65, 75 and 96 match the real layout.
  - **Audiences** (from `AUDIENCES.md`): self-hoster (primary) and the infrastructure-as-code consumer.
- **Touched files / artifacts**: new `docs/{en,de}/getting-started/data-disk.md`; `docs/{en,de}/getting-started/updates.md`; `docs/{en,de}/references/configuration.md`; `docs/{en,de}/getting-started/index.md`; `mkdocs.yml`; `README.md`.
- **Specialist**: `nolte-shared:audience-doc-author` (the audience artifact `AUDIENCES.md` exists).
- **Depends on**: P2, P4, P5, P6, P7, P8.
- **Traces to**: R19 (documents R1–R17).

### P11 — Security gate before the PR

- **Problem statement**: The change formats disks, handles a LUKS key, and moves secrets onto removable media, so a security review is mandatory before the PR.
- **Acceptance criteria**:
  - The built-in `security-review` runs on the branch diff against `develop` (from a session whose working directory holds the change).
  - `nolte-engineering:code-security-reviewer` runs a whole-codebase pass focused on the data-disk script, `configure`, `kamerplanter-update` and the units.
  - Explicitly checked: no formatting path is reachable for an unnamed or foreign disk (device-name injection, a second disk spoofing the label); the key is never logged and never written to the data disk; key and secrets use modes 0600/0700; no secrets copy stays on the system disk beyond the R10 fallback copy and its deletion; an unprivileged user cannot trigger the override.
  - Every Critical or High finding is fixed (and the review re-run green) or explicitly accepted by the operator, and triaged under Findings.
- **Touched files / artifacts**: none directly; fixes land in the owning package's files.
- **Specialist**: built-in `security-review` + `nolte-engineering:code-security-reviewer`.
- **Depends on**: P3–P9.
- **Traces to**: R1, R11, R13, R14, R19.

## Dependency ordering

```
P1 → P2 → P3
P3 → P4 → P5
P3 → P6        (parallel to P4)
P3 → P7        (parallel to P4)
P3, P4 → P8
P3..P8 → P9
P2, P4..P8 → P10   (alongside P9)
P3..P9 → P11 → PR
```

Commit order: P1 (no commit) → P2 → P3 → P4 → P6 → P7 → P5 → P8 → P9 → P10 → P11 fixes → fix-forward `git rm` of this artifact.

## Risks

| Risk | Status | Mitigation |
|---|---|---|
| `/etc` under bootc: the ostree `/etc` merge may copy data-disk files into the next deployment (secrets on the system disk, a second data state), or break a bind mount or symlink across update and rollback | unestablished; settled by P1 question 1 | P1 runs first; P3–P5 build only on the mechanism P1 shows; option (c) moves the authoritative location out of `/etc` |
| Window generator reads the user file before mounts | established: `kamerplanter-update-window:12` | P1 question 2; P4 checks `TimersCalendar` |
| Secrets generated on the system disk while the data disk is missing | established: `configure:74-76`, `:89-100` | P3: the config service requires the data-disk unit whenever a disk is set up; P9 case 5 asserts no new `secrets.env` |
| Formatting the wrong disk (destructive) | design risk | Format only an explicitly named disk; refuse foreign signatures (Q1); P11 checks it |
| Two disks labelled `kp-data` (e.g. a cloned stick) | unestablished | P3 refuses to mount and names both devices |
| Database files on USB sticks (wear, power loss under RocksDB) | not assessed (requirements open risk) | Documented in P10; recommend a USB disk or SSD over a stick |
| File system and formatting tool | engineering choice | P1 question 5; default ext4, as in `build/disk.sh:76` |
| A4 across disk moves; development builds vs releases | on-device rule established: `kamerplanter-update:84-98` | P6 reuses `forward`; the spec states the dev-build rule (Q4); P9 case 6 |
| Names of the missing-disk and override commands, and where their status shows | left open by the requirements | Decided in P3/P6, then written into the specs and docs within this PR |
| LUKS key handling (leaks into logs, the data disk, or readable files) | security-sensitive | P7 criteria; **code-security-reviewer and security-review MUST run before the PR (P11)** |
| Unencrypted backup disk holds a full database copy | design risk | Q3; documented in P10 |
| TPM path untestable: the tool container has no `swtpm` (`build/tools.Containerfile:5-8`) | established | R14 allows the system disk or the TPM; build and test the system-disk key file first |
| Base image may lack `cryptsetup` or `mkfs.*` | unestablished; settled by P1 question 4 | `dnf install` in `image/Containerfile`; record the image size change |
| Boot-test duration: first boot can take up to 1500 s (`run.sh:17`) | established | Reuse overlays across cases where state allows; separate script and task |
| Test paths hard-code the volume path (`update.sh:31`, `variants/Containerfile`) | established | P1 question 3 prefers a placement that keeps them valid; otherwise P9 updates them |
| One large PR is harder to review | accepted by the operator | One commit per package; the PR body maps commits to packages and R-ids |
| Sporadic `ostree-finalize-staged` failure ("Remounting /boot read-write: Invalid argument") seen in u2 on 2026-11-14 | unestablished cause; upstream-known message | Not in scope here; tracked separately; boot tests that apply updates may hit it |

## Open questions

**Resolved 2026-11-14:** the operator approved the plan and accepted the proposed default for Q1–Q4 ("das passt!"). P2 writes them into the specs.

1. **Q1 (before P3).** Should a named disk that already carries a file system or partition table other than our two labels be formatted, or refused? *Proposed default:* refuse with a message naming the signature found; format only with an explicit force setting.
2. **Q2.** How is a disk named, and under which credential name? The user file itself moves onto the disk, so on a fresh VM the name must come from a system-side source. *Proposed default:* a `/dev/disk/by-*` path or a device path, given as a setting in the user file and as a systemd credential of the same name.
3. **Q3.** Does "set up the same way" (R15) include LUKS for the backup disk? *Proposed default:* yes, under the same R14 key rule, since the backup holds a full database copy.
4. **Q4.** How do development builds relate to the release marker? Under `forward` (`kamerplanter-update:92-98`), a dev build is refused on a disk marked by any release. *Proposed default:* keep that rule; the tests mark disks with the test-variant versions.

## Findings

| Finding | Source | Outcome | Reproduction | Issue |
|---|---|---|---|---|
| Window generator reads the user file before mounts | plan grounding | to be fixed in P4 | `image/rootfs/usr/lib/systemd/system-generators/kamerplanter-update-window:12` | — |
| `configure` creates and fills `secrets.env` unconditionally | plan grounding | to be fixed in P3 | `image/rootfs/usr/libexec/kamerplanter/configure:74-100` | — |

| ext4 labels hold at most 16 characters (xfs 12); `kamerplanter-data` was truncated to `kamerplanter-dat`, so mounting by label failed | P1 spike run 1 | fixed directly: operator chose labels `kp-data` / `kp-backup`; requirements R1, R2, R11, R15 revised | `mkfs.ext4 -L kamerplanter-data` → "Warning: label too long; will be truncated to 'kamerplanter-dat'" | — |
| P1 Q4 toolset: base image ships `mkfs.ext4`, `mkfs.xfs`, `cryptsetup` 2.8.8, `systemd-cryptsetup`, `systemd-cryptenroll`, `wipefs`, `blkid`, `tpm2_getcap` (tpm2-tss 4.2.2) | P1 spike run 1 | established; no `dnf install` needed | `command -v …`, `rpm -q …` in a VM from `.build/disk.raw` | — |
| P1 Q1 `/etc`: bind mount of `<disk>/etc` onto `/etc/kamerplanter` survives an ostree `/etc` merge (new deployment staged and booted) and a rollback; content written after the move (`SENTINEL`, an added line) stays on the disk and is **not** copied into any deployment's `/etc` on the system disk; only the pre-move files remain underneath (the R10 fallback copy) | P1 spike run 2 (GitHub Actions run 43605692183) | established: option (a) bind mount chosen; the underlying pre-move copy is the R10 fallback and is removed by P5's cleanup | A2/A4/A5: `findmnt` shows `/etc/kamerplanter /dev/sdb[/etc]`; `ls /sysroot/ostree/deploy/default/deploy/*/etc/kamerplanter/` lists only `kamerplanter.env` (942 B, pre-move) and `secrets.env`, no `SENTINEL`, no post-move line | — |
| P1 Q2 window: the generator runs before the mount, so the timer keeps the default; a `systemctl daemon-reload` after the mount picks up the disk's value | P1 spike run 2 | established: P4 triggers a daemon-reload (or writes a runtime drop-in) after the data disk is mounted | `TimersCalendar` at boot `03:00:00`, after `daemon-reload` `05:17:00` (value only in the disk's user file) | — |
| P1 Q3 volumes: bind mounts of `<disk>/volumes/{arangodb_data,valkey_data}` over `/var/lib/containers/storage/volumes/<name>` work; Podman's volume mountpoint stays `/var/lib/containers/storage/volumes/arangodb_data/_data`, so `kamerplanter-update:36-38` and the test paths stay valid | P1 spike run 2 | established: bind volumes chosen; Quadlet `.volume` files unchanged | A2/B2 `findmnt`, `podman volume inspect`, containers healthy | — |
| P1 adoption (R8): a fresh VM (own first-boot secrets `6f870a95…`) with the same disk and the mount units adopts the disk: `secrets.env` sha `6bf48c29…` equals the original appliance's, pins pass, all services healthy, API 200 | P1 spike run 2 | established; in the product the mount precedes the first `configure`, so no secrets are generated on the system disk at all | B1/B2 log | — |
| P1 Q5 file system: ext4 (labels ≤ 16 chars, matches `build/disk.sh:76`); `kp-data`/`kp-backup` also fit xfs | P1 spike | decided: ext4 | — | — |
| Hosted runners offer KVM: the spike booted QEMU/KVM guests on `ubuntu-latest` after a udev rule for `/dev/kvm` | P1 spike run 2 | established; settles step 1 of the planned CI VM-test workflow | workflow `spike-data-disk` on `exp/data-disk-spike` | — |
| Spec readiness: E13 release marker blocked the rollback to the previous release after a failed update (MUST vs MUST) | spec-readiness-reviewer on 477b634 (Critical) | fixed directly: marker records the highest release that passed its health check, and is part of the D2 backup | `spec/distribution-requirements/en.md` E13 | — |
| Spec readiness: E10 "generate no secret" contradicted D10 for a newer release on an older disk | spec-readiness-reviewer (Critical) | fixed directly: E10 generates only secrets the disk does not hold | E10 | — |
| Spec readiness: label-length claim without source | spec-readiness-reviewer (Critical) | fixed directly: [R12] mke2fs(8), [R13] mkfs.xfs(8), spike run cited | Context, References | — |
| Spec readiness warnings: E11 vs E12, E6 scope, A7 vs override, E4 per system, "set up" undefined, backup-disk detection, R19 coverage, missing ACs, D5 AC, OQ blocking status | spec-readiness-reviewer (Warning) | fixed directly in the same commit; E3 growth of a data disk left as non-blocking open question | E6–E16, U&R A7/D8–D10/E4, DT D9 | — |
| Security: label-only identity let a prepared or cloned `kp-data`/`kp-backup` medium be adopted or receive backups (SR-001, SR-003) | security-requirements-reviewer (Critical) | fixed directly after operator decision: adoption only of a named disk, UUID recorded and enforced (E8, E10), backup disk only under its identity, backup checksum (U&R D10); R8 revised | E8, E10, U&R D8, D10 | — |
| Security: key as setting would travel onto the data disk with the user file (SR-002) | security-requirements-reviewer (Critical) | fixed directly after operator decision: credential or system-side file only (E14); R14 revised | E14 | — |
| Security: unencrypted backup of an encrypted data disk (SR-004) | security-requirements-reviewer (Critical) | fixed directly after operator decision: E16, U&R D8 parity rule; R20 added | E16, U&R D8 | — |
| Security warnings SR-005–SR-012 (mount hardening, modes, override actor, naming paths and system-disk guard, deletion of copies, locked disk, key storage, encryption before first write) and suggestions SR-013/SR-014 | security-requirements-reviewer | fixed directly in E7–E14 and DT D9; SR-017 (retention vs GDPR Art. 17) recorded as a question for legal review, not decided here | E7–E14, DT D9 | — |
| P3 note for P4: a fresh ext4 data disk carries no SELinux labels; the bind mounts into containers need labelling (`:Z`, `context=` or `restorecon`) | P3 specialist report | carried into P4 | — | — |
| P3 note for P7: LUKS header and inner file system both labelled `kp-data` would be classified as duplicates by `classify`; exclude the container's mapper device or label the inner file system differently | P3 specialist report | carried into P7 | `image/rootfs/usr/libexec/kamerplanter/disks` `classify` | — |
| P3 not verified in a booted VM: unit ordering at runtime, SMBIOS credentials, system-disk detection on bootc (`/sysroot`), SELinux | P3 specialist report | carried into P9 boot tests | loop-device integration run 38/38 in the tool container (scratchpad, not in the repo) | — |
| W1 (High): root followed symbolic links on removable media: `cleanup` globbed `"$base"/*/` and ran `rm -rf -- "$dir"` with a trailing slash (GNU rm empties the link target); `write_backup`, `forget_backup` and `backup_base` used the paths unchecked | P11 security review | fixed: `backup_create`/`backup_delete`/`backup_entries`/`backup_entry_problem` in env.sh (names `sha256:<64 hex>` only, base and entry no link, same file system, `find -type d`, `rm --one-file-system`, no `install -d` over a link); update tool uses them in `forget_backup`, `write_backup`, `backup_problem`, `cleanup`; disks refuses a data or backup disk whose `update-backup`, an entry in it, or `release` is a link or of the wrong type (`top_problem`, `layout_problem`) | unit backup.sh "entry link"/"base link" (victim survives), disks.sh "update-backup …"; loop P11 T1–T7; the 07ee59c update tool empties the victim in the same set-up (reproduced) | — |
| W2 (High): disk naming and `*_FORCE` read from the user file, which lies on the data disk when the backup unit runs | P11 security review | fixed after operator decision: credential or `/var/lib/kamerplanter/disks/naming.env` (root, not writable by others, parsed by `load`; written by `disks name ROLE PATH [force] \| none`); the user file names disks only while no data disk is set up and `/etc/kamerplanter` is no mount, else ignored with a journal line naming `disks name`; `naming` runs after `fall_back`. `UPDATE_BACKUP_KEEP_DAYS` floored at 3 (`keep_days`). Spec E7/E9 en+de, docs en+de | unit disks.sh "naming: …", backup.sh "keep: …"; loop P11 U1–U4 | — |
| LUKS `cipher_null` (Medium): an opened container was not checked for its data segment cipher | P11 security review | fixed: luksFormat with explicit `aes-xts-plain64`/512, recorded as `CIPHER`/`KEY_BITS`; `check_cipher` (`cryptsetup status`) after open and for an open mapper; records without the fields accept only the format values, never `cipher_null`; mismatch closes the mapper and fails like an identity failure. cryptsetup 2.8.8 itself refuses `cipher_null` keyslots | unit disks.sh "cipher: …"; loop P11 N0–N5 (forged header same UUID, set-up, old record, adoption) | — |
| W4: `/etc/credstore.encrypted/` copy never deleted (`cmp` against plaintext) | P11 security review | fixed: encrypted copies compared via `systemd-creds decrypt --name=… - \| cmp`, deleted when equal; message reworded. systemd.exec(5) of systemd 262 in the image: ImportCredential searches `/etc/credstore`, `/run/credstore`, `/usr/lib/credstore` and the `.encrypted` counterparts, no `/usr/local/lib`, no `.cred` suffix; `/usr/lib` is the read-only image and is not touched | loop P11 E0–E1 | — |
| W5: key accepted from the kernel command line (world-readable, journaled) | P11 security review | fixed: `cmdline_key` refuses `systemd.set_credential(_binary)=kamerplanter.ROLE-disk-key:` (also quoted, `rd.`), unit fails, key not stored; docs en+de forbid the channel | unit disks.sh "cmdline: …"; loop P11 K1 | — |
| N1 (Medium, re-review): `cmdline_key` missed spellings systemd accepts (`-` for `_` in the parameter, double quotes anywhere in a word, `-binary`, `rd.`) | P11 security re-review | fixed: `cmdline_key` tokenises like systemd (blanks outside quotes, all double quotes dropped), normalises `-` to `_` in the parameter name only, matches the four parameters exactly and the credential name before the first `:` exactly; only the verdict leaves awk | unit disks.sh "cmdline: …" (11 new, incl. negatives) | — |
| S5: names written unsanitised to `/run/issue.d`, journal and console | P11 security review | fixed: `die` and `report` pass message and hint through `shown`; conflict, naming warnings and `ignore_naming` too | unit disks.sh "naming: a conflict is shown without control characters"; loop P11 S1 | — |
| S6: `clean-underneath` ran in any namespace; plain `remount,rw` of `/sysroot` first | P11 security review | fixed: refuses unless `/proc/self/ns/mnt` differs from `/proc/1/ns/mnt`; only `remount,bind,rw` | unit disks.sh "clean-underneath: refused …"; loop P11 C1; positive path (d4-cleanup) unverified locally, CI | — |
| S7: `*_FORCE` "used once" tracked per path string | P11 security review | fixed: `forced` records `device_identity` (WWN, else serial, with partition number; device number as fallback), old path lines still count; docs "once per device" | unit disks.sh "identity: …"; loop P11 F1 (alias path refused) | — |
| W3, I1, I2, I4: forgeable identity of unencrypted disks, firmware key copies, shred on flash/CoW, replay of an old encrypted image | P11 security review | accepted by the operator, documented in "Residual risks" of `docs/{en,de}/getting-started/data-disk.md` | — | — |
<!-- P1 spike results are appended here: one row per question with command and output. -->

## Dispatch log

<!-- <YYYY-MM-DD> P<k> dispatched to <subagent_type> — <result one-liner> -->
2026-11-14 plan approved by the operator, Q1–Q4 defaults accepted.
2026-11-14 P1 done by the generalist (spike on GitHub Actions, run 43605692183): bind mounts for `/etc/kamerplanter`, pins and volumes; daemon-reload after the mount for the window; ext4; toolset complete; adoption works.
2026-11-14 P2 done via the `nolte-shared:spec` skill (run in the orchestrating session): distribution-requirements E2/E5 amended, E6–E15 added with acceptance criteria and a Context paragraph from the P1 spike; deployment-targets D3 widened, D9 added, NFS non-goal; update-and-rollback A7, D8, D9 added, D2/D5 amended, open question on the update state after a system replacement. en/de drift check clean; committed as 477b634.
2026-11-14 P2 reviews: `nolte-shared:spec-readiness-reviewer` (3 Critical, 12 Warning) and `nolte-shared:security-requirements-reviewer` (4 Critical, 8 Warning, 2 Suggestion) on 477b634; all fixed in one follow-up commit after three operator decisions (named adoption with UUID, key never in the user file, backup protection parity).
2026-11-14 P3 dispatched to `nolte-engineering:fullstack-developer` — data-disk service `disks` with `kamerplanter-{data,backup}-disk.service`: naming via `DATA_DISK`/`BACKUP_DISK` (by-id/by-uuid) or credentials `kamerplanter.data-disk`/`kamerplanter.backup-disk`, safe formatting, UUID record under `/var/lib/kamerplanter/disks/`, mount `nosuid,nodev,noexec` at `/var/mnt/kamerplanter-{data,backup}`, missing disk stops the services and blocks `configure`; unit checks 49/49, loop-device integration 38/38, `task image:build` and lint green.
2026-11-14 branch rebased onto develop fe279e9 (#18, #19, #20); P4 dispatched to `nolte-engineering:fullstack-developer`.
2026-11-14 P4 done by `nolte-engineering:fullstack-developer`: `disks start data` binds etc, pinned and both volumes from the disk (list in env.sh `data_disk_places`), restorecon after binding, undo on any failure, daemon-reload only when the window changed; `configure` and the guard require `data_disk_placed`; volume units ordered after the disk service; `copy_volumes` keeps bind mount points; a named disk on a system that already holds data is refused until P5. Unit checks 83/83, loop-device integration 51/51, image build, lint green. VM checks (SELinux/AVC, TimersCalendar, shutdown order, ArangoDB with root-owned `_data`) carried into P9.
2026-11-14 P6 done by `nolte-engineering:fullstack-developer`: marker `<disk>/release` (0600) holds the highest release that passed its health check; `release_version`/`forward` moved to env.sh as the one comparator; guard runs `release_check` after any restore and fails (containers stay stopped) on a newer or unreadable marker, message on console, journal and log.jsonl; marker raised after a healthy update or by `mark_when_healthy` on first install/adoption; marker copied into each pre-update backup and restored on rollback; dev builds refused on any marked disk and never mark; `kamerplanter-update allow-downgrade <disk> <running>` root-only, only for the active pair, recorded in update/downgrades and log.jsonl; config now ordered after the guard. Unit checks 129/129, loop-device integration 44/44, image build, lint green. Target restart after override and refusal in a VM carried into P9; command name, marker path and unreadable rule into P10.
2026-11-14 P7 done by `nolte-engineering:fullstack-developer`: LUKS2 for data and backup disk with key from credential `kamerplanter.{data,backup}-disk-key` or `/var/lib/kamerplanter/disks/keys/`, 32-8192 bytes, stored as `keys/ROLE.key` 0600 in 0700, provisioning copies (keys/, credstore) deleted after storing; key only via --key-file; identity = LUKS2 UUID, record `ENCRYPTION=`; classify skips the own mapper (dm-UUID/slaves checked), clones still duplicates; key for an unencrypted disk refused (unit fails); E16 backup parity; stored key deleted when no record; `disks stop` closes the mapper. No TPM (PCRs change with every bootc update). Unit checks 164/164, loop integration 69/69 with real cryptsetup, systemd-as-PID-1 run 8/8, P4/P6 regressions green, leak check clean. Open: real boot with SMBIOS credential, shutdown order, argon2 cost on small hardware (P9); P11 review.
2026-11-14 operator decision: a key supplied for a disk set up unencrypted keeps the services stopped (not: refuse and continue unencrypted), since the provisioner evidently expects encryption.
2026-11-14 P5 done by `nolte-engineering:fullstack-developer`: move onto a newly named disk with record `move.env` (copying → moved → verified → cleaned, or falling-back → failed), copy verified by tree listing + cmp + sync before `moved`, binds only from `moved`; interrupted copy restarts from scratch; health via the existing health service (`check_move` in `cmd_health`); fallback through a restart of the disk unit (record removed, naming ignored until named anew, key deleted); system copy (incl. deployment /etc copies via private mount namespace) deleted by `cleanup` after `UPDATE_BACKUP_KEEP_DAYS`; missing disk is E12, no fallback. Unit checks 216/216, P5 integration 70/70 incl. resets at five points, P4/P6/P7 regressions green. Open: target restart does not restart the disk unit (move at runtime needs reboot or unit restart), /sysroot remount and SELinux for unshare in a VM (P9).
2026-11-14 operator decision: the disk unit stays out of kamerplanter.target (no PartOf); a move at runtime needs a reboot or `systemctl restart kamerplanter-data-disk.service`, documented in P10.
2026-11-14 P8 done by `nolte-engineering:fullstack-developer`: pre-update backup to the first location of backup disk → data disk → system disk that passes identity, protection parity (system disk counts as protected for an encrypted data disk only with the stored key) and space; skipped locations and reasons in log.jsonl; per-backup record `update/backups/<D>` with location, UUID and SHA-256 tree checksum (D10), checked before automatic and manual restore; missing location or mismatch refuses the restore and keeps services stopped; data-disk backups under `<disk>/update-backup/`; cleanup at all locations with pending deletion for a missing disk. tests/unit/backup.sh 68/68, disks.sh 216/216, P8 integration 59/59, P4-P7 regressions green. Open: rollback to a release without P8 does not find a backup off the system disk (operator decision pending).
2026-11-14 operator decision: the pre-update backup goes only to a location the release it would roll back to can find (system disk when that release lacks backup-location support); follow-up dispatched to the P8 specialist.
2026-11-14 P8 follow-up done: `/usr/lib/kamerplanter/features` lists `backup-locations`; the guard reads it from the rollback deployment (bootc status rollback slot, digest must equal the release being left, path validated) and uses only the system disk when it is missing or the target unknown. backup.sh 83/83, P8 integration 65/65, P5/P6 regressions green. Readability of the rollback deployment /usr on composefs carried into P9.
2026-11-15 P9 done by general-purpose (generalist): `tests/boot/data-disk.sh` (`task test:data-disk`), `start_vm` extras (VM_DISKS, VM_CREDENTIALS incl. binary, VM_MONITOR hotplug); data-disk run 17/17 PASS (d1 none, d4 move + cleanup via fetch unit, d2 data, d3 replace with login/token/Fernet kept, d5 missing + reattach, d6 dev build refused + allow-downgrade, d7 LUKS argon2id unlock ~2.8 s on 2 vCPU, d8 backup disk set-up); `task test:boot` 9/9 PASS; update.sh gains u2-features (rollback deployment features readable) and a fix for DISK resolving empty on a fresh checkout (disk.sh then overwrote `.build/disk.raw`); `task test:update` re-run (2026-11-15, before 07ee59c): u1, u1-source, u3, u5, u6 PASS; u2 FAIL ("apply missed: dcdae1df27ec was not booted", suspected bootc#1673 ostree-finalize-staged, no journal collected), u2-features FAIL (rollback deployment null, fixed by 07ee59c to skip), u3-forward and u4 SKIP; the run then crashed at its end because update.sh was edited while it ran. Not re-run since: per operator decision the VM tests run in CI on the PR. Not done: backup to the backup disk during a real update and its fallback, `health` warning output (need a failing update), TPM (no swtpm). Pre-existing: kmscon cannot read /run/issue.d (var_run_t) in the no-disk baseline as well.
2026-11-15 P10 done by `nolte-shared:audience-doc-author`: new page `docs/{en,de}/getting-started/data-disk.md` (what lives where, choosing a disk with the removable-media and USB-stick wear warning, naming by setting or credential, format/adopt/refuse/force, `disks status`, move with record states and re-naming after a failed move, adoption by a fresh system via credential, missing disk, release marker and `allow-downgrade`, LUKS2 key rules and limits, provisioning credentials with a QEMU SMBIOS example, retiring a disk per DT D9); `updates.md` gains the backup-location order, the 10 % + 512 MiB rule and restore refusal; `configuration.md` the disk settings, credentials and the revised Backups warning; nav and nav_translations; README "data partition" wording. `mkdocs build --strict` and pre-commit green (no Vale configured). Open: no supported path back from a data disk to the system disk or to another data disk (documented as a limitation); console display of `/run/issue.d` messages not claimed (kmscon issue).
2026-11-15 P11 security gate: findings W1, W2, LUKS cipher_null, W4, W5, S5, S6, S7 fixed by `nolte-engineering:fullstack-developer` (2dbc96c code + unit checks, 780ebb7 boot test keep period, 559dd90 spec E7/E9/E14 en+de, docs en+de with a "Residual risks" section for W3/I1/I2/I4 and the key on the system disk, requirements decision). tests/unit/disks.sh 263/263 (was 216), backup.sh 119/119 (was 83); loop integration P11 52/52 in the tool container (incl. the 07ee59c update tool emptying a link target); regressions P5 70/70, P8 65/65 (harness digests relaxed), P7 67/69 (E1 message reworded by W4; X1 device order of blkid); `task image:build`, pre-commit, `mkdocs build --strict` green. VM tests (`task test:data-disk`, `task test:update`, `task disk:build`) not run locally per operator decision; they run in CI.
