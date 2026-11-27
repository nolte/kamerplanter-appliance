# CLAUDE.md

Orientation for Claude Code and contributors working inside this repository.

## What this repo is

The Kamerplanter appliance: a Fedora bootc system image (`image/`) that runs the Kamerplanter stack, plus the disk image built from it, the update and rollback tooling, and the tests that boot it in VMs. What it must do is specified under `spec/` (`spec/distribution-requirements/` is the main one); the user documentation lives under `docs/{en,de}/`.

## Verification runs on GitHub, never on the notebook

Image builds, boot and VM tests, and the test suites load a laptop for an hour and have run it out of memory. Locally run only:

- `bash -n <script>` and other syntax checks;
- `pre-commit run --files <changed files>` (shellcheck, yamllint and the other hooks).

Everything else runs on GitHub:

- `ci.yml` on every pull request: `pre-commit`, `docs-build`, `unit-tests` (all three required on `develop`);
- `vm-tests.yml` (build, boot, update and data-disk suites): on a pull request with the label `vm-tests`, after a merge to `develop` that touches what it covers, or by hand on a pushed branch with `gh workflow run vm-tests.yml --ref <branch> -f suites=<all|boot|update|data-disk>`;
- `vm-gate` (required): a commit status that is green only when a pull request changes nothing the VM tests cover, or carries `vm-tests` and its VM suites passed (`.github/workflows/vm-gate.yml` decides on every pull request; `.github/workflows/vm-gate-finalize.yml`, a `workflow_run` on `develop`, sets the result of the VM tests, also for a pull request from a fork).
- The label `vm-tests` is the consent to running one head, and a push can withdraw it: `vm-gate.yml` removes the label, and `vm-gate` fails until it is set again, when the push changes the pull request's own version of `vm-tests.yml`, `build/`, `tests/boot/` or `tests/image/` (a fix-forward to a test script, a new digest in `build/tools.Containerfile`), when the head is in a fork, or when the commit before the push never got an accepted `vm-gate`. A push that changes only `image/` or other paths, and a rebase or a merge of `develop` that leaves those four paths as the pull request had them, keep the label. A label set less than 5 minutes after someone else pushed the head is removed again as well (`vm-gate` fails with "the label was set less than 5 minutes after a push or a reopening"): look at the head again and set the label once it is 5 minutes old; the one who pushed the head to a branch of this repository (Renovate, or `gh pr create --label vm-tests` after your own push) is not held up (#151). After such a push, wait until the label is gone (`gh pr view <n> --json labels`) before setting it again: setting a label that is still there fires no event and starts nothing.

A failing VM job is evidence, also when it is not required: compare it with the last runs on `develop` (`gh run list --workflow vm-tests.yml --branch develop`) before calling it a flake. The failure artifacts (`vm-results-*`) hold `*.diagnose.txt` with the journal of the previous boot.

## Working copies and pull requests

- The primary checkout stays on `develop`. Work happens in a worktree: `task worktree:add -- <branch> [slug]` creates `${NOLTE_WORKTREE_ROOT:-~/repos/.worktrees}/kamerplanter-appliance/<slug>/` off `origin/develop`; `task worktree:remove -- <slug>` retires it after the merge.
- One pull request against `develop` at a time (Renovate's included); pull requests merge by squash through the `automerge` label.
- `.audits/` and `.resume/` are ignored: pre-analysis artifacts and resume state stay untracked and never need a `git rm` before a merge.
- `Closes #N` does not fire on a merge into `develop`; close the issue by hand with a reference to the pull request and the merge commit.

## Things that broke before

- **Base image digests disappear.** Fedora removes superseded `fedora-bootc` and `fedora` digests within about a day; the system image builds from the mirror `ghcr.io/nolte/kamerplanter-appliance-base`, the tool container (`build/tools.Containerfile`) from `ghcr.io/nolte/kamerplanter-appliance-tools-base` (both `.github/workflows/base-image-mirror.yml`; the pre-commit hook `fedora-base-from-mirror` refuses a Fedora base (`FROM`, `COPY --from` or `ARG` default) on `quay.io/fedora`, `registry.fedoraproject.org` or a short name). "manifest unknown" means a pin outside the mirror. A new mirror pair has no tag until the workflow ran once: dispatch it on the branch before that branch builds from it, and make the new package public, since the builds pull without a login (#48). In the package's settings, under "Manage Actions access", also add this repository with the role Write: although a run of the workflow created the package, the next scheduled run was refused with `permission_denied: write_package` until the role was granted (#118).
- **The update window depends on `/boot` staying mounted.** `ostree-finalize-staged` writes a staged release at shutdown; the base image's `/boot` automount used to unmount after 120 idle seconds and the release was dropped (#39, fixed by `boot.automount.d/kamerplanter.conf`). Diagnostics must not touch `/boot` or other automounted paths: reading them remounts them and hides the failure.
- **Existing installations.** A stricter configuration check can stop the services of a device that already runs, so every update fails its health check and rolls back. A change to `configure` or the update tool states what happens to an upgraded installation.

## Conventions

- Code, commits, pull requests, specs and issues in English; the user documentation in English and German, kept in step (`docs/en`, `docs/de`; `spec/<topic>/en.md` canonical, `de.md` its translation).
- Conventional-Commits titles; the branch prefix (`feat/`, `fix/`, `chore/`, `docs/`, `exp/`) sets the type. A `fix` pull request carries the `## Class sweep` section with a measured predicate.
- Shell scripts run under `set -euo pipefail` and never print a secret value.
