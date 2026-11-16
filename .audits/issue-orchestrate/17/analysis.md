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
| P1 Q1 image: `dnf install cloud-init` adds cloud-init 26.2 and 23 Python/tooling packages (11 MB `cloudinit`); `bootc container lint` passes with 3 warnings (content in /run,/tmp; non-empty /var/log; /var content without tmpfiles.d) | P1 spike, GitHub runs 43611879282, 43626093374, 43640039007 on `exp/provisioning-spike` | established; P2 must clean /run, /tmp, /var/log and add tmpfiles.d for /var/lib/cloud | `rpm -q`, `comm` of rpm lists, lint output | — |
| P1 no source (R5): cloud-init is disabled by its generator ("No ds found … Disabled cloud-init"); DHCP and first-boot setup unchanged, boot 1 min | P1 spike C1 | established | `cloud-init status --long`: `disabled-by-generator` | — |
| P1 seed files on the disk: `/var/lib/cloud/seed/nocloud/{meta-data,user-data}` present before and after the reboot, yet ds-identify reports "No ds found" at 2.5 s; `var.mount` becomes active at 3.68 s, so the generator cannot see /var. With `datasource_list: [ NoCloud, None ]` ds-identify takes the single entry and the seed directory works (`DataSourceNoCloud [seed=/var/lib/cloud/seed/nocloud]`) | P1 spike C2/C3 (run 43640039007) | established: seed files need a design that does not rely on ds-identify detection with several datasources (e.g. a seed location visible before /var, a ds-identify policy drop-in, or documenting a NoCloud-only drop-in for that mode); decided in P2 | `ActiveEnterTimestampMonotonic=3681635`; ds-identify `[up 2.51s] returning 1`; C3 `single entry in datasource_list (NoCloud None) use that.` | — |
| P1 CIDATA ISO, vfat drive and seed URL via SMBIOS serial all detected (`seed=/dev/sr0`, `seed=/dev/sdb`, `DataSourceNoCloudNet [seed=dmi,http://10.0.2.2:8099/]`); hostname set (cloud-init warns "Failed to set the hostname" although `hostnamectl` shows it), `write_files` target 0600, user-data SSH key works for root | P1 spike A1/A2, B1, D1 | established | status lines per run; `ssh -i userdata_key root@…` succeeded | — |
| P1 static network not applied: cloud-init writes `cloud-init-primary.nmconnection` (`method=manual`, both addresses, route, DNS) but with `interface-name=primary` — the v2 id, not the matched device — so it never activates; NetworkManager keeps its default "Wired connection 1" (DHCP, autoconnect-priority -999) | P1 spike A1 (run 43640039007) | established: the network-config with `match:` but no `set-name` yields an unusable keyfile; P2/P7 must test a config keyed by the real name, by `macaddress` with `set-name`, and confirm cloud-init renders before NetworkManager creates its default connection | keyfile content and `nmcli con show` in the log | — |
| P1 default user: a user `fedora` is created from the stock `default_user`; Q1 needs `users: []`/no default user in the image drop-in | P1 spike A1 | established | `getent passwd fedora` | — |
| P1 schema: the `kamerplanter:` key makes `cloud-init schema` fail and the status `degraded done` on every run; `cc_resizefs` warns about `/dev/composefs` | P1 spike A1, B1, D1 | established: P2 disables resizefs/growpart; the degraded status from an unknown top-level key must be accepted and documented or avoided (e.g. vendor schema extension) | WARNING lines in `cloud-init status --long` | — |
| P1 secret copies (R13): the marker appears in `instances/<id>/user-data.txt`, `user-data.txt.i`, `cloud-config.txt`, `obj.pkl` and `/run/cloud-init/combined-cloud-config.json`; journal 0 hits; after deleting them and rebooting with the drive still attached, all copies are back | P1 spike A3/A4 | established: scrubbing only holds once the source is gone; with the source attached cloud-init re-reads it every boot. P5 must scrub on every boot (or stop cloud-init from caching user-data) and the docs must require detaching the drive | file list before and after reboot | — |
| P1 metadata restriction (R13): nftables rule `ip daddr 169.254.169.254 meta skuid != 0 drop` lets root through (200), blocks `nobody` and the backend container (timeout) | P1 spike Q5 | established: nftables (1.1.6, already installed) works; firewalld not installed | `curl`/`urllib` results | — |
| P1 credentials (R11): SMBIOS type 11 `io.systemd.credential:kamerplanter.secret.JWT_SECRET_KEY=…` arrives as a system credential (40 B, `secure`) and reaches a unit via `ImportCredential=kamerplanter.secret.*`; the value is not in the journal | P1 spike B1 | established | `systemd-creds --system list`; `$CREDENTIALS_DIRECTORY` listing; journal hits 0 | — |
| P1 harness: the spike hung twice after Q5 (guest session kept open, first by a background server, then by the podman exec); bounded with `timeout`/ServerAliveInterval in the third run | P1 spike | spike tooling only; P7 boot tests bound every guest command | `### run ended with 124` | — |
| P1 Hetzner/OpenStack (R3): not exercised; ds-identify lists the datasources but the spike had no metadata double for them | P1 spike | unestablished: needs a real target or a test double (risk already recorded) | — | — |

## Dispatch log

<!-- <YYYY-MM-DD> P<k> dispatched to <subagent_type> — <result one-liner> -->
2026-11-14 plan approved by the operator, Q1–Q5 defaults accepted; sequencing: #15 merges first.
2026-11-14 P1 done by the generalist (three spike runs on `exp/provisioning-spike`): all NoCloud forms detected except seed files with several datasources (/var mounts after the generator); static network not applied (keyfile bound to the v2 id); default user `fedora` created; cached secret copies return while the source is attached; nftables metadata restriction and systemd credentials work.
2026-11-15 P2 done by spec (general-purpose agent following the spec skill) — new §L (L1–L20) in distribution-requirements, D4/D11/E7 and H6 plus the provisioning-data row extended, en+de; seed files need a NoCloud-only drop-in (L3), degraded status accepted (L8), network forms to be verified by P7 (L6).
2026-11-15 operator confirmed the P2 interpretations: R2 met with the NoCloud-only drop-in precondition for seed files (L3); R12 once per instance at the first boot that can write secrets.env (L12); data-disk naming keys ignored in the provisioning layer (L11/L19); SSH password login stays off even when user-data asks (L5); `degraded done` from the `kamerplanter:` key accepted and documented (L8).
2026-11-15 P3 done by nolte-engineering:fullstack-developer — cloud-init 26.2 in the image (22 packages, +27 MiB installed, layer 68.6 MB), drop-in `50-kamerplanter.cfg` with `[ NoCloud, ConfigDrive, Hetzner, OpenStack, None ]`, no default user (`default_user: null`), root keys, growpart/resizefs off; sshd drop-in `10-kamerplanter.conf` keeps password login off over cloud-init's `50-cloud-init.conf`; `bootc container lint` clean; nm-cloud-setup left disabled (base, preset disabled); boot behaviour left to P7.
2026-11-15 P4 done by nolte-engineering:fullstack-developer — new kamerplanter-provisioning.service (After=cloud-init-network.service, kamerplanter-data-disk.service; After= only) renews /var/lib/kamerplanter/provisioning/settings.env (root 0600 in 0700, system disk) from `kamerplanter.settings` of cloud-init's /run/cloud-init/combined-cloud-config.json on every boot with a datasource other than None, keeps it otherwise, and reloads systemd when the window differs; write_files target provisioning.env loaded before it (map wins); one layer list `config_layers`/`load_config` in env.sh used by configure, kamerplanter-update `count()`, the window generator and disks; naming keys dropped from the layer with a message, secret keys passed through with a key-only warning, provisioned failures name the layer; tests/unit/provisioning.sh 49 new checks (all fail on 15449be); image builds, `bootc container lint` passes, no ordering cycle in `systemd-analyze verify`; boot behaviour left to P7/P8.
2026-11-16 P5 done by nolte-engineering:fullstack-developer — kamerplanter-provisioning stages `kamerplanter.secrets` as KEY=VALUE lines (jq straight to file, invalid entries as value-free message lines) in /run/kamerplanter-provisioning/ (tmpfs, 0700/0600, outside /run/kamerplanter which configure empties on failure) with cloud-init's instance id, unless /var/lib/kamerplanter/provisioning/secrets-taken already names that instance; configure, after `data_disk_placed`, takes staged map + credentials (`ImportCredential=kamerplanter.secret.*` on kamerplanter-config.service, credential wins) into missing keys of secrets.env only (atomic, 0600, existing keys kept; held differing value kept with key-only warning per Q5), allowlist = the five D9 keys + TENANT_EXPORT_SIGNING_SECRET, values 1–4096 printable ASCII and the existing per-key format rules (shared `secret_problem`); pinned keys restored only on digest match, otherwise stopped (or warned when another layer holds the key); any invalid provisioned key/value keeps the services stopped and writes nothing; after the take-over it records the instance and deletes the staging; tests/unit/secrets.sh 55 checks (45 fail on cbf1408, 10 regression baselines); scrub of cloud-init copies left to P6 (order After=kamerplanter-provisioning.service); boot behaviour left to P8.
2026-11-16 operator confirmed the P5 interpretations: TENANT_EXPORT_SIGNING_SECRET provisionable; an invalid provisioned secret keeps the services stopped; strictly once per instance (a boot with data but no secrets: counts); secret values printable ASCII only.
2026-11-16 P6 done by nolte-engineering:fullstack-developer (stopped uncommitted, reviewed and finished in the next session) — kamerplanter-cloud-init-scrub.service (After=kamerplanter-provisioning.service cloud-final.service, every boot) deletes user-data.txt{,.i}, cloud-config.txt, obj.pkl per instance and combined-cloud-config.json, instance-data-sensitive.json, replaces provisioned secret values (secrets: plus secret keys under settings:, ≥ 8 chars) by REDACTED in the rest of /var/lib/cloud, /run/cloud-init and cloud-init*.log, keeps data/instance-id, the instance link and sem/, warns on seed files holding secrets, fails when a value is left; kamerplanter-metadata-guard.service loads its own table inet kamerplanter_metadata before network-pre.target (output: uid ≠ 0 rejected, forward: rejected, IPv4 and fe80::a9fe:a9fe), every container Requires/After it; tests/unit/scrub.sh 43 checks, tests/image/metadata-guard.sh (netns, needs the built image) not yet run; operator approved committing, image test and systemd-analyze verify move to P10/CI.
2026-11-16 P7 done by the generalist — tools container gains dosfstools, mtools, python3; start_vm gains VM_SMBIOS, VM_NIC, VM_GUEST_ADDR, VM_SSH_KEY=off and a FORMAT in VM_DISKS (current call sites unchanged); run_1 records cloud-init disabled + DHCP (L4); run_9 CIDATA vfat drive, network-config matched by MAC with set-name lan0, static 10.0.2.50; run_10 seed URL in the SMBIOS serial (python3 http.server on 10.0.2.2:8099); run_11 CIDATA drive keyed by the interface name eno1 (acpi-index=1), static 10.0.2.51; each checks hostname, SSH with the user-data key only, password login refused despite ssh_pwauth: true, no default user, and the static address/gateway/DNS; vm-tests.yml gains jobs "run 9" and "runs 10 11" and runs tests/image/metadata-guard.sh in the build job; lint clean; nothing booted yet (CI only).
2026-11-16 P8 done by the generalist — run_9 gains, after the P7 checks: first start with FRONTEND_URL from the map (map wins over write_files' provisioning.env, REGISTRATION_MODE from write_files applies), backend NRestarts=0, UPDATE_WINDOW 04:15 in the timer; JWT_SECRET_KEY from secrets: and LOG_PSEUDONYM_SALT from the SMBIOS credential kamerplanter.secret.* in secrets.env, secrets-taken = run9; scrub active and no marker in /var/lib/cloud, /run/cloud-init, cloud-init*.log or the journal; metadata table loaded; reboot with the drive attached: settings apply, config_write_files semaphore unchanged, secret not staged or taken again, no copies; boot with the drive detached keeps settings and secret. run_11 gains UPDATE_WINDOW "25:00" (config failed, backend stopped, message names the provisioning layer), DATA_DISK ignored with a message, FERNET_KEY under settings warned by key only and absent from the journal. Lint clean, nothing booted yet (CI only).
2026-11-16 vm-tests run 43953268563 (boot): build and metadata-guard check green; runs 1–8 green incl. run1-noprov; runs 9/10/11: everything PASS (both L6 network forms, settings at first start, secrets + credential, scrub incl. reboot with drive attached, detached drive, invalid value) except two test-side expectations (sshd -T case, JSON-quoted instance id in secrets-taken by design) — fixed in the harness. Earlier run 43950596999 failed on a vanished base digest on develop; operator had PR #28 merged and the branch rebased.
2026-11-16 AUDIENCES.md revisit accepted by the operator (inside boundary + provisioning data; IaC open question on the mechanism resolved; self-hoster surface extended).
2026-11-16 P9 done by nolte-shared:audience-doc-author — new references/provisioning.md en+de, four-layer table and secret channels in configuration.md, index + nav (+ i18n translation), data-disk cross-link; Hetzner/OVH and the Proxmox-generated network config marked as not yet tested in visible notes; L6 forms documented as supported after runs 9/11 passed; mkdocs build --strict and pre-commit green.
2026-11-16 vm-tests run 43957047107 (boot): all jobs green, runs 1–11 PASS.
2026-11-16 P10 nolte-engineering:code-security-reviewer — no Critical; fixed: SEC-005 (jq `$` matched before a final line break, a staged line could carry a value into the journal; \A..\z anchors + configure never echoes a non-message line; regression test fails on the old step), SEC-003 (config Requires= provisioning: fail closed instead of generating), SEC-015 (scrub After= config), SEC-016 (restorecon after rewriting a log), SEC-011 (/var/lib/cloud/seed 0700), SEC-013 (settings_lines drops jq stderr), docs for SEC-002/008/010; dismissed SEC-001 (podman 6.1.3 reads --env-file literally, verified); deferred to issues: SEC-004/007, SEC-006, SEC-009, SEC-012, SEC-017.
