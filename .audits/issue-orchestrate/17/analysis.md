---
artifact-type: issue-orchestration-analysis
repo: "nolte/kamerplanter-appliance"
issue: "17"
classification: "feature-request"
secondary-classes: ["spec-change", "security"]
route: "direct"
status: approved
created: "2026-11-14"
---

# Issue Orchestration — Pre-analysis

<!-- Run-scoped artifact: committed on feat/provisioning, removed with a fix-forward
     `git rm` before the PR merges (spec/project/issue-orchestration/ §Pre-analysis
     artifact lifecycle). Durable facts go to the PR's Risk / rollout notes and the
     issue comment first. -->

Drafted by `nolte-engineering:implementation-plan-author` on 2026-11-14 and written to disk by the orchestrator (the agent may not write report files).

## Issue metadata

- **Repository**: nolte/kamerplanter-appliance
- **Issue**: #17 — feat: accept configuration through provisioning data (cloud-init)
- **URL**: https://github.com/nolte/kamerplanter-appliance/issues/17
- **Labels**: enhancement
- **Author**: nolte (repository owner, trusted author); no comments; no milestone, no assignee
- **Linked items**: #15 (optional data disk, plan approved, being built on `feat/data-disk`); nolte/kamerplanter-infrastructure#8 (secret rotation and later configuration via Ansible, out of scope here); follow-up `appliance_config` input in nolte/kamerplanter-infrastructure (Terraform, out of scope)
- **Requirement artifact**: `project/requirements/provisioning.md` (R1–R19, all `confirmed`, `U_gate` = 0.8 = `τ_high`, termination `saturation`); the requirements gate is met
- **Base**: `origin/develop` @ `51d7a56`, worktree `/home/nolte/repos/.worktrees/kamerplanter-appliance/provisioning`, branch `feat/provisioning`
- **Prior art checked**: no `project/features/` or `project/roadmap.md`; no open PRs; open issues #2, #3, #4, #7, #15 — none implements provisioning. `spec/distribution-requirements/en.md:237` names the gap as an open question; `spec/deployment-targets/en.md:34` already assumes cloud-init on every target. Not self-resolved.

## Classification

- **Primary class**: feature-request
- **Secondary class(es)**: spec-change, security
- **Rationale**: Adds a new capability (provisioning client and a configuration layer). It changes D4/D11/H6 of two specs and introduces secrets in provisioning data, the cloud-init cache and the metadata service as a new attack surface. Operator decision 2026-11-14; recorded, not reopened.
- **Asserted cause verified**: confirmed — `image/Containerfile:7-55` installs no package; `rpm -q` in `localhost/kamerplanter-appliance:poc` shows cloud-init, afterburn and ignition not installed, only `nm-cloud-setup` present. The open question in `spec/distribution-requirements/en.md:237` says the same.

## Scope

- **In scope**
  - cloud-init in the system image with its full module set (R1). Reading NoCloud from a `CIDATA` drive, a seed URL (kernel command line or SMBIOS serial) and seed files under `/var/lib/cloud/seed/nocloud/` (R2), and from the Hetzner Cloud and OVHcloud metadata services (R3). Applying hostname, network and SSH keys at boot (R4). Unchanged DHCP behaviour without provisioning data (R5).
  - A provisioning configuration layer for Kamerplanter settings, fed from `kamerplanter:` → `settings:` and a documented `write_files` target (R7), applied on every boot in the order defaults → provisioning → secrets → user file (R8), validated like the user file (R9). All three readers of the layers stay consistent (`configure`, `kamerplanter-update`, the window generator).
  - Secret channels: self-generation stays the default (R10); systemd credentials (R11); `kamerplanter:` → `secrets:` taken into `secrets.env` on the first boot only (R12); pin rules unchanged (R14).
  - Hardening (R13): scrub the secret copies cloud-init keeps, and restrict the metadata service to root.
  - Spec changes in `spec/distribution-requirements/` and `spec/deployment-targets/` (en + de) (R17).
  - Boot tests for the R18 cases, including the tool-container support they need.
  - Documentation en + de: interface, lifecycle, secret paths, protection, hardening, and the R6 warning (R6, R19).
- **Out of scope**
  - The Terraform side (`appliance_config` input) → nolte/kamerplanter-infrastructure.
  - A secret rotation command on the appliance (R15) → nolte/kamerplanter-infrastructure#8.
  - Data-disk naming and its LUKS key (R16) → #15; any #15 work (data-disk mounts, bind mounts of `/etc/kamerplanter`, adoption).
  - Wiring the QEMU boot tests into CI (`grep -l tests/boot .github/workflows/*` is empty); the planned CI VM-test workflow takes the new runs.
  - Preventing cloud-init modules that write under `/usr` or install packages; documented as a warning only (R6).

## Route

- **Decision**: direct
- **Rationale**: One coherent goal outcome: the appliance accepts provisioning data. All work lands on `feat/provisioning` as **one pull request with ordered commits**, per the operator decision of 2026-11-14 (same as for #15). No roadmap item is created or retargeted.
- **Pipeline hand-off**: n/a

## Detected context

- **Stack**: Fedora bootc system image (`image/Containerfile`, base `quay.io/fedora/fedora-bootc:46@sha256:88c6…`); rootfs overlay `image/rootfs/` (`COPY rootfs/ /` at `image/Containerfile:15`); Bash tooling under `set -euo pipefail` and `umask 077`; systemd units, Quadlet containers, a systemd generator; the build ends with `bootc container lint` (`image/Containerfile:55`).
- **Configuration**: `image/rootfs/usr/libexec/kamerplanter/configure` defines the layers (`:9-12`, paths `:21-25`), pins (`:30-34`), secret generation (`:81-100`), validation (`:101-136`), the error message that keeps services stopped (`:138-144`, names the user file at `:141`, deletes `/run/kamerplanter/*.env` at `:142`) and the output (`:148-151`). Shared parser `image/rootfs/usr/lib/kamerplanter/env.sh:15-36` (contract `:2-7`). `kamerplanter-config.service` is a oneshot with default dependencies (`:5-8`); `kamerplanter.target` uses `DefaultDependencies=no` (`:8`); the container drop-in sets `Requires=`/`After=kamerplanter-config.service`.
- **Other readers of the layers**: `image/rootfs/usr/bin/kamerplanter-update:39-40` and `count()` at `:50-56` load defaults + user only; `kamerplanter-update-window:12` loads defaults + user only.
- **Tests**: `tests/boot/run.sh` (`start_vm` `:37-65`; SSH key as systemd credential via SMBIOS type 11 at `:44`; hostfwd without explicit guest address at `:57`; default run list `:237`); `tests/boot/update.sh:19` sources `run.sh`; tasks `test:boot` / `test:update` (`Taskfile.yml:89-99`). Tool container `build/tools.Containerfile`: `python3` present; `xorriso`, `genisoimage`, `dosfstools`, `mtools`, `cloud-utils` not installed (`rpm -q`).
- **Quality gate**: pre-commit (trailing-whitespace, check-yaml, yamllint, shellcheck) and `mkdocs build --strict` (`.github/workflows/ci.yml:24-54`).
- **Specs**: `spec/.spec-config.yml` (`canonical_language: en`, `languages: [en, de]`). `spec/distribution-requirements/en.md`: D4 `:98`, D11 `:105`, D12 `:106`, F1/F4 `:118-121`, G3 `:130`, open question `:237`, target table `:21`. `spec/deployment-targets/en.md`: provisioning-data table `:33-34`, E1/E2 `:100-101`, H6/H7 `:128-129`, acceptance criterion `:159`.
- **Docs**: `docs/en/references/configuration.md` (three-layer table `:11-17`), `docs/en/getting-started/index.md`, nav `mkdocs.yml:130-139`. Audiences (`AUDIENCES.md`): self-hoster (primary, `user-docs`); infrastructure-as-code automation (`developer-docs`, open question "cloud-init is not in the image yet").

## Work packages

### P1 — Feasibility spike: cloud-init in the bootc image, datasources, every-boot layer vs cache scrub, ordering, metadata restriction, QEMU NoCloud supply, credentials

- **Problem statement**: Design risks from the requirement artifact and the code are unsettled; every later package builds on their answers. Settle them on a throwaway branch / Actions run before product code lands.
- **Acceptance criteria**: each question has a row in §Findings with command, observed output and decision; no spike code merged into `feat/provisioning`.
  1. **Package and lint.** Variant of `image/Containerfile` with `dnf -y install cloud-init`: added packages and size; cloud-init version; `bootc container lint` result (incl. `/var/lib/cloud` without tmpfiles.d); shipped `/etc/cloud/cloud.cfg` (`default_user`, `disable_root`, `ssh_pwauth`, module lists and stages); systemd unit names and their ordering; whether `nm-cloud-setup.service`/`.timer` is enabled.
  2. **Datasources.** A `datasource_list` drop-in under which `ds-identify` detects NoCloud from a `CIDATA` ISO and a vfat drive, from `ds=nocloud;s=http://10.0.2.2:<port>/` in the SMBIOS serial, from `/var/lib/cloud/seed/nocloud/`, and disables cloud-init without a source. For Hetzner and OpenStack/OVH record how `ds-identify` decides (DMI) and whether a test double is feasible.
  3. **R8 vs R13.** A mechanism that re-reads `kamerplanter.settings` every boot while no copy of `kamerplanter.secrets` stays on disk: (a) a custom cloud-init module (`always` for settings, `once-per-instance` for secrets) or (b) a unit after cloud-init running `cloud-init query userdata`. Enumerate every persisted copy (`/var/lib/cloud/instance{,s/<id>}/user-data.txt*`, `obj.pkl`, `/run/cloud-init/instance-data-sensitive.json`, seed dir, `/var/log/cloud-init*.log`, journal); show zero matches for a marker secret, also after a reboot with the drive attached. Record whether the unknown top-level key `kamerplanter:` causes schema warnings or `degraded` status.
  4. **Ordering.** Provisioning layer and staged secrets exist before `kamerplanter-config.service` at first boot; no ordering cycle (`systemd-analyze verify`); no wait when cloud-init is disabled; a provisioned `UPDATE_WINDOW` reaches the timer at first boot (`daemon-reload` after the provisioning step, as in #15's spike).
  5. **Metadata restriction.** A rule (record `rpm -q nftables firewalld`) limiting 169.254.169.254 to uid 0 on output and blocking it from the Podman network on forward; demonstrated with a local HTTP double inside QEMU.
  6. **QEMU supply.** How `tests/boot/run.sh` attaches a NoCloud drive (`xorriso`/`mkfs.vfat`+`mcopy` vs QEMU `vvfat`) and serves a seed URL (`python3 -m http.server`, guest reaches 10.0.2.2); static IPv4 in 10.0.2.0/24 reachable through `hostfwd` with an explicit guest address; time of one extra first boot.
  7. **systemd credentials (R11).** Naming (`kamerplanter.secret.<KEY>` or one env-format credential); `ImportCredential=`/`LoadCredential=` on `kamerplanter-config.service` with SMBIOS type 11 in QEMU; how Proxmox VE passes one (`args: -smbios type=11,…` needs `root@pam`, or `fw_cfg`).
- **Touched files / artifacts**: §Findings rows only; spike branch `exp/provisioning-spike` (optionally a temporary workflow there).
- **Specialist**: no matching specialised agent — generalist remediation
- **Depends on**: none

### P2 — Specs: provisioning interface, lifecycle and secret policy (en + de)

- **Problem statement**: The specs name provisioning data only as an input (D4, H6) and leave configuration through provisioning open (`spec/distribution-requirements/en.md:237`). Interface, layer order, lifecycle, secret channels and hardening must become normative first (R17).
- **Acceptance criteria**:
  - `spec/distribution-requirements/en.md`: D4 names the sources; D11 names the provisioning layer and the order defaults → provisioning → secrets → user file; new numbered requirements for R7–R16; the open question at `:237` resolved; matching acceptance criteria; the target table (`:21`) consistent.
  - `spec/deployment-targets/en.md`: H6 and the provisioning-data table (`:33-34`) name NoCloud drive, seed URL and seed files for Proxmox VE, mini PC and private targets, and the metadata services for Hetzner and OVH; `:159` stays valid; E2/H7 unchanged in substance.
  - `de.md` translations match; the `spec` skill's index and drift checks pass; requirement IDs do not collide with those #15 adds (check `feat/data-disk`).
- **Touched files / artifacts**: `spec/distribution-requirements/{en,de}.md`, `spec/deployment-targets/{en,de}.md`, `spec/README.md` (only if the index changes)
- **Specialist**: `nolte-shared:spec` (skill)
- **Depends on**: P1

### P3 — cloud-init in the image: datasources, root SSH policy, unchanged behaviour without data

- **Problem statement**: No provisioning client, so hostname, network and SSH keys from provisioning data have no effect (D4, H6; R1–R5).
- **Acceptance criteria**: `image/Containerfile` installs cloud-init (R1); an image-shipped `/etc/cloud/cloud.cfg.d/` drop-in sets the `datasource_list` from P1 (NoCloud, Hetzner, OVH-capable source, None) and the account policy of Q1 (key for root, no default user, `ssh_pwauth: false`); `bootc container lint` passes; with a `CIDATA` drive hostname, static IPv4/gateway/DNS and SSH key are in effect; without a source DHCP and first-boot setup as before (P7); the SSH credential path (`tests/boot/run.sh:44`) still works.
- **Touched files / artifacts**: `image/Containerfile`; new `image/rootfs/etc/cloud/cloud.cfg.d/50-kamerplanter.cfg`; presets/masks only if P1 requires
- **Specialist**: `nolte-engineering:fullstack-developer`
- **Depends on**: P1, P2

### P4 — Provisioning configuration layer for Kamerplanter settings

- **Problem statement**: Settings come only from `/etc/kamerplanter/kamerplanter.env`; provisioned settings need their own every-boot layer, validated like the user file and seen identically by all three readers (R7–R9).
- **Acceptance criteria**:
  - **Sources:** `kamerplanter:` → `settings:` and the documented `write_files` target feed the layer (R7); relative order per Q3.
  - **Layer order:** `configure` loads defaults → provisioning → secrets → user file (R8); a provisioned value is in `/run/kamerplanter/app.env` at the first start; a changed value applies after the next boot; the user file still wins.
  - **Validation:** an invalid provisioned line or value keeps the services stopped with the same message format, naming the provisioning source (`configure:141`) (R9).
  - **Readers:** `kamerplanter-update` `count()` and the window generator load the same layer set; the `env.sh` contract holds; a provisioned `UPDATE_WINDOW` reaches the timer at first boot (P1 mechanism).
  - **Placement:** the layer does not live in `/run/kamerplanter/` (emptied at `configure:142`).
  - **Ordering:** `kamerplanter-config.service` is ordered after the provisioning step with `After=` only.
  - The comment header of `image/rootfs/etc/kamerplanter/kamerplanter.env:1-3` names the new layer; shellcheck clean.
- **Touched files / artifacts**: `configure`, `env.sh`, `kamerplanter-update`, `kamerplanter-update-window`, `kamerplanter-config.service`, `image/rootfs/etc/kamerplanter/kamerplanter.env`, the new provisioning step (custom cloud-init module or unit + script under `image/rootfs/usr/libexec/kamerplanter/`), `image/Containerfile`
- **Specialist**: `nolte-engineering:fullstack-developer`
- **Depends on**: P3

### P5 — Secret channels: first-boot take-over from cloud-init and systemd credentials (security-sensitive)

- **Problem statement**: Provisioners need to supply secrets before the first start through `kamerplanter:` → `secrets:` (first boot only) and systemd credentials, with self-generation as default and pins intact (R10–R12, R14, R15).
- **Acceptance criteria**:
  - Without provisioned secrets, `secrets.env` is generated exactly as today (R10).
  - A secret under `kamerplanter:` → `secrets:` is written to `secrets.env` on the instance's first boot, before any service starts; it only fills a missing key, never overwrites; a conflict is handled per Q5; a later boot does not take it over again (R12).
  - A secret passed as a systemd credential (naming per P1/Q4) fills a missing key the same way (R11).
  - Provisioned pinned values pass the format checks and are pinned at first start; a value differing from an existing pin keeps the services stopped (`configure:131-136`); a matching value restores a missing key (R14).
  - No secret value in the journal or configure output; no rotation command (R15); data-disk channel untouched (R16).
- **Touched files / artifacts**: `configure`; `kamerplanter-config.service` (`ImportCredential=`/`LoadCredential=`); the P4 provisioning step (staging to a root-only tmpfs path)
- **Specialist**: `nolte-engineering:fullstack-developer`; security chain in P10
- **Depends on**: P4

### P6 — Hardening: scrub cloud-init's secret copies, restrict the metadata service (security-sensitive)

- **Problem statement**: Copies of provisioned secrets stay under `/var/lib/cloud` and `/run/cloud-init`; on hosted targets every local process and container can read the metadata service (R13).
- **Acceptance criteria**: after the first boot with a `secrets:` map, `grep -rF <marker>` over `/var/lib/cloud`, `/run/cloud-init` and `/var/log/cloud-init*.log` finds nothing, settings still apply on the next boot, and this holds after a reboot with the drive attached (scrub every boot, settings re-read before it); uid 0 reaches 169.254.169.254, non-root processes and containers do not; a boot without a source is unaffected.
- **Touched files / artifacts**: new scrub unit and script; nftables ruleset/unit (per P1); `image/Containerfile`
- **Specialist**: `nolte-engineering:fullstack-developer`; security chain in P10
- **Depends on**: P5

### P7 — Boot tests, provisioning client: NoCloud drive, no data (DHCP), seed URL

- **Problem statement**: R18's client cases need a NoCloud drive and a seed URL in the QEMU harness; the tool container has no ISO/vfat tool and `start_vm` neither attaches a second drive nor forwards SSH to a static guest address (`tests/boot/run.sh:37-65`, `:57`).
- **Acceptance criteria**: `build/tools.Containerfile` provides the P1 tool; `start_vm` gains optional parameters (extra drive, SMBIOS serial, guest address for hostfwd, SSH credential on/off) without changing current call sites; a NoCloud-drive run checks hostname, static 10.0.2.x address with gateway and DNS, and SSH with a key only in the user-data; `run_1` asserts cloud-init disabled or idle and DHCP; a seed-URL run (SMBIOS serial, `python3 -m http.server`) checks hostname and SSH key; PASS/FAIL in `results.tsv`; new runs in the default list; shellcheck clean.
- **Touched files / artifacts**: `build/tools.Containerfile`; `tests/boot/run.sh`; `tests/boot/fixtures/nocloud/…`; `Taskfile.yml` (only if needed)
- **Specialist**: no matching specialised agent — generalist remediation
- **Depends on**: P3

### P8 — Boot tests, settings and secrets: `FRONTEND_URL` at first start, cloud-init secret plus scrub, credential secret, invalid value

- **Problem statement**: The remaining R18 cases prove the layer and the secret paths end to end.
- **Acceptance criteria**: `podman exec backend printenv FRONTEND_URL` shows the provisioned value with backend `NRestarts=0`; a `secrets:` marker lands in `secrets.env` and `grep -rF` over the cloud-init locations finds nothing, also after a reboot with the drive attached; a SMBIOS type 11 credential fills `secrets.env`; an invalid provisioned value (e.g. `UPDATE_WINDOW=25:00`) keeps `kamerplanter-config.service` failed and the backend inactive (R9); PASS/FAIL recorded; shellcheck clean.
- **Touched files / artifacts**: `tests/boot/run.sh`; `tests/boot/fixtures/nocloud/…`
- **Specialist**: no matching specialised agent — generalist remediation
- **Depends on**: P6, P7

### P9 — Documentation (en + de): interface, lifecycle, secrets, hardening, warning

- **Problem statement**: Self-hosters and the infrastructure automation need the interface, lifecycle, secret paths and their protection, and the hardening steps documented (R6, R13, R19).
- **Acceptance criteria**: `configuration.md` shows four layers in order and links the provisioning page, its generated-secrets section names the cloud-init and credential channels; a new provisioning page (en + de) documents the NoCloud forms and hosted sources, a cloud-config example with `kamerplanter:` → `settings:` / `secrets:` and the `write_files` target, the lifecycle, the pin rules, the credential form for Proxmox VE/QEMU, scrub and metadata restriction, detaching the drive / deleting snippets and the plain-text-at-rest caveat, and the R6 warning; nav entry, `mkdocs build --strict` passes, frontmatter per `AUDIENCES.md`; the `AUDIENCES.md` open question resolved through `nolte-shared:audience-identify`.
- **Touched files / artifacts**: `docs/{en,de}/references/configuration.md`, new `docs/{en,de}/references/provisioning.md`, `docs/{en,de}/references/index.md`, `mkdocs.yml`, `AUDIENCES.md` (via `audience-identify`)
- **Specialist**: `nolte-shared:audience-doc-author` (agent); `nolte-shared:audience-identify` (skill)
- **Depends on**: P2, P6

### P10 — Security and quality gate before the PR

- **Problem statement**: Secrets in provisioning data, a cloud-init cache, a credential import, a scrub and a network restriction are security-sensitive and need the audit→fix→verify chain before the PR.
- **Acceptance criteria**: `nolte-engineering:code-security-reviewer` runs a whole-codebase pass focused on `configure`, the provisioning step, the scrub, the credential import, the metadata rule and the cloud.cfg drop-in; every Critical/High finding fixed by the owning package's specialist or filed with rationale; the built-in `security-review` verifies the final diff; `quality-gate` green (pre-commit, `mkdocs build --strict`); `task test:boot` and `task test:update` pass locally or on a KVM runner.
- **Touched files / artifacts**: fixes routed back to P4–P6; §Findings
- **Specialist**: `nolte-engineering:code-security-reviewer` + built-in `security-review`; `nolte-engineering:quality-gate`
- **Depends on**: P2–P9

## Dependency ordering

```
P1 ─┬─> P2 ─> P3 ─┬─> P4 ─> P5 ─> P6 ─┬─> P8 ─┐
    │             └─> P7 ─────────────┘       │
    │                         P2,P6 ─> P9 ────┤
    └──────────────────────────────────────────> P10 (after all)
```

Commit order on the single PR strand: **P1 (spike, no commit) → P2 → P3 → P4 → P5 → P6 → P7 → P8 → P9 → P10**. P7 may run in parallel with P4–P6 once P3 is in (disjoint files).

## Risks

| # | Risk | Status | Mitigation |
|---|---|---|---|
| R-1 | cloud-init pulls in python3 and dependencies (footprint), its `/var/lib/cloud` content may trip `bootc container lint` | unestablished: P1 Q1 | P1 first; tmpfiles.d entry if lint warns; record the size in the PR |
| R-2 | Fedora's `cloud.cfg` may create a `fedora` default user and set `disable_root: true` | unestablished: P1 Q1 | P3 drop-in per Q1; `ssh_pwauth: false` |
| R-3 | Unknown top-level `kamerplanter:` key may give schema warnings or `degraded` status | unestablished: P1 Q3 | module schema or documented warning |
| R-4 | R8 (every boot) vs R13 (scrub): with a still-attached drive or a hosted metadata service, cloud-init re-caches secrets on every boot | unestablished: P1 Q3 | extract settings before the scrub every boot; scrub every boot; P8 asserts after a reboot with the drive attached |
| R-5 | First-boot ordering: `kamerplanter.target` has `DefaultDependencies=no`; cloud-init unit names vary; cycles or waits possible | target established (`kamerplanter.target:8`); unit names/cycle unestablished: P1 Q4 | `After=` only; P7's `run_1` asserts the no-data path |
| R-6 | The window generator runs before cloud-init and reads only defaults + user | established: `kamerplanter-update-window:12` | P4 adds the layer and a `daemon-reload` after the provisioning step (pattern proven by #15's spike) |
| R-7 | Readers diverge: `configure` loads three layers, `kamerplanter-update` and the generator two | established: file:line | P4 changes all three; optional shared layer-list helper in `env.sh` |
| R-8 | A layer under `/run/kamerplanter/` is deleted on validation failure | established: `configure:142` | P4 places it elsewhere |
| R-9 | The metadata restriction can break cloud-init or miss container traffic; `nftables` presence unknown | unestablished: P1 Q5 | rule on output (uid ≠ 0) and forward (Podman network); P10 review |
| R-10 | Secrets leak via logs (configure output, cloud-init debug log, journal, `cloud-init query`) | unestablished: P1 Q3 | never echo values; scrub covers logs; P10 |
| R-11 | slirp `hostfwd` without guest address targets 10.0.2.15, so SSH to a static address fails | established: `tests/boot/run.sh:57` | P7 passes an explicit guest address; static IP in 10.0.2.0/24 |
| R-12 | Tool container lacks an ISO/vfat tool | established: `rpm -q` | P7 adds the P1 tool or uses QEMU vvfat; seed URL via `python3 -m http.server` |
| R-13 | Test runtime: 2–3 extra first boots; boot tests not in CI today | KVM on hosted runners established (2026-11-14, run 43605692183) | combine cases per VM; CI wiring via the planned VM-test workflow |
| R-14 | Overlap with #15 (`feat/data-disk`): both change `configure`, `kamerplanter-update`, the window generator, `start_vm`, specs and docs; #15 bind-mounts `/etc/kamerplanter`, so a `write_files` target there written before the mount would be hidden; take-over must write into an adopted `secrets.env` | established: `feat/data-disk:.audits/issue-orchestrate/15/analysis.md` | merge the PRs one after the other, rebase the later one, re-run both sides' boot tests; order the data-disk mount before cloud-init; take-over fills only missing keys; check spec IDs against #15's P2 |
| R-15 | Hetzner and OVH datasources unverified (OVH may expose OpenStack) | unestablished | `[runtime-verify]` caveat in the PR; not in the R18 boot tests |
| R-16 | Full module set on an immutable system: modules writing under `/usr` or installing packages fail or do not persist | established by design | documented warning (R6, P9) |
| R-17 | Secrets at rest on NoCloud drives and Proxmox snippet storage | established (outside appliance control) | documented: detach and delete after the first boot (R13, R19) |
| R-18 | `nm-cloud-setup` and cloud-init's NetworkManager renderer may conflict with NM's default DHCP connection | unestablished: P1 Q1, P7 | mask or leave per P1; P7 asserts addresses |
| R-19 | Re-provisioning with a new instance-id re-runs per-instance steps | design consequence | take-over fills only missing keys; conflicts per Q5 |

## Open questions

**Resolved 2026-11-14:** the operator approved the plan with the defaults of Q1–Q5 ("ja"), and decided to finish and merge #15 before #17 is built on top of it (R-14).

- **Q1 — SSH account for provisioned keys.** Default: root (matches `tests/boot/run.sh:44` and the docs), no cloud-init default user, `ssh_pwauth: false`. Alternative: a named admin user with sudo.
- **Q2 — Secret keys under `settings:`.** A `FERNET_KEY` under `settings:` would stay in the every-boot layer and in the cache. Default: (a) pass through but log a warning and document "use `secrets:`" (R9 stands). (b) reporting it as invalid would amend R9 and need re-confirmation.
- **Q3 — Precedence inside the provisioning layer** between the `kamerplanter.settings` map and the `write_files` file. Default: the map wins; the `write_files` target is a dedicated file such as `provisioning.env`, never the user file.
- **Q4 — systemd credential semantics.** Default: one credential per key, `kamerplanter.secret.<KEY>`; fills a missing key on any boot (same rule as Q5); documented for Proxmox via `args: -smbios type=11,…` (needs `root@pam`).
- **Q5 — Provisioned secret differing from an existing `secrets.env` value.** Default: keep the existing value, log a warning naming the key but never the value, start normally. Alternative: keep the services stopped.

## Findings

| Finding | Source | Outcome | Reproduction | Issue |
|---|---|---|---|---|
| `kamerplanter-update` and the window generator ignore `secrets.env`, while `configure` reads it; harmless today | plan grounding | dismissed as not a defect (they read only update keys); P4 keeps the readers consistent for the new layer | `kamerplanter-update:53`, `kamerplanter-update-window:12` vs `configure:81` | — |
| Boot tests are not run by any workflow | plan grounding | out of scope; planned CI VM-test workflow | `grep -l tests/boot .github/workflows/*` → empty | — |
<!-- P1 spike results are appended here: one row per question with command and output. -->

## Dispatch log

<!-- <YYYY-MM-DD> P<k> dispatched to <subagent_type> — <result one-liner> -->
2026-11-14 plan approved by the operator, Q1–Q5 defaults accepted; sequencing: #15 merges first.
