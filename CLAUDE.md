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
- The label `vm-tests` is the consent to running one head, and a push can withdraw it: `vm-gate.yml` removes the label, and `vm-gate` fails until it is set again, when the push changes the pull request's own version of `vm-tests.yml`, `build/`, `tests/boot/` or `tests/image/` (a fix-forward to a test script, a new digest in `build/tools.Containerfile`), when the head is in a fork, or when the commit before the push never got an accepted `vm-gate`. A push that changes only `image/` or other paths, and a rebase or a merge of `develop` that leaves those four paths as the pull request had them, keep the label. After a push that withdraws the label, wait until the label is gone (`gh pr view <n> --json labels`) before setting it again: setting a label that is still there fires no event and starts nothing.
- A label set too soon is removed again as well (#151): less than 5 minutes after someone else pushed the head, or after the pull request was reopened, `vm-gate` fails with "the label was set less than 5 minutes after a push or a reopening". The same holds for a label that lands a second or two after someone else's push, so that the push's own event already carries it (#182): the push's run removes it. To tell that label from one set before the push, a push to a labelled pull request that the rules above leave the label, that changes something the VM tests cover and that is still the head reads GitHub's records of the push and of the label (up to six times, 25 s); if they cannot be read, the label is removed with "the time of the push or of the label could not be read", also on a push that would have kept it. After that status on a bot's push (a Renovate rebase), it is not established that anyone sets the label again (#158): set it by hand, and not before the head is 5 minutes old, or it is removed as set too soon. In every case: look at the head again and set the label once the head is 5 minutes old. The one who pushed the head to a branch of this repository (Renovate, or `gh pr create --label vm-tests` after your own push) is not held up; a head in a fork always waits the 5 minutes.
- A run of `vm-tests` on a pull request starts with the job `consent` (#152), which reads the label and `vm-gate` from the API: the run of a push that lost the label, and of a label that was removed again, ends there green with every other job skipped, and tests nothing. Setting the label again starts the run that tests the head. A red `consent` means the label is set but `vm-gate` did not accept the head within 10 minutes (or the API did not answer): read what `vm-gate` says, then remove the label and set it again, or re-run the failed jobs if `vm-gate` has accepted the head meanwhile. A red `consent` with "this commit is not the head of #N any more" is the new attempt of an old run (#180): nothing to do, the head has a run of its own. A new attempt that runs `consent` again (all jobs, or the failed ones when `consent` was among them) on a pull request that is closed or merged ends there green as well, with "#N is closed" or "#N is merged" in the summary and every other job skipped (#195). The job is the pull request's own version, so it saves runners and protects nothing; the result is protected by `vm-gate`.
- The suite jobs (`boot`, `update`, `data-disk`) read the label once more in their first step, after the build (#180). Removing the label while the build runs (about 5 minutes) makes all of them fail there with "No test result: … does not have the label vm-tests any more": that red is not evidence about the image, and `vm-gate-finalize.yml` writes no result while the label is gone; if the label is set again before that run has completed, `vm-gate` reads "did not pass (boot: failure)" until the run of the new label has its result. A suite job that has passed that step runs to its end (up to about 17 minutes) whatever happens to the label, and removing the label and setting it again while a run goes on still builds and tests the head a second time: to ask for a new run of a head, wait for the running one to end.

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
