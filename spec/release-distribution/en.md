# Release Distribution

Status: draft

## Context

A user installs the appliance from a file they download: an installer ISO or a disk image. That file becomes the operating system of their server, so a manipulated copy would hand the whole machine to an attacker. This spec states how the delivery artifacts come into existence, where they are published, and how a user can prove that a file is the one this project built. The route is the one the surrounding projects already use: a GitHub Actions workflow builds the artifacts and publishes them as assets of a GitHub release.

Established on 2026-11-12. This repository contains no workflow yet: its working tree holds `README.md` and `spec/` only (`git status`). The upstream project `nolte/kamerplanter` already publishes through a release-drafter draft and a `release-publish.yml` workflow and attests its container images with `actions/attest-build-provenance` (`.github/workflows/` in a working copy). This repository inherits the portfolio specs of the hub `nolte/claude-shared` at tag `v0.1.11` (`spec/.spec-config.yml`); that release carries, among others, `project/release-automation`, `project/release-artifact`, and `project/branching-model` (`git grep` for `Portfolio-Scope: portfolio` at the tag). The hub's `develop` branch additionally carries `artifact-signing` and `continuous-delivery`; they are absent from `v0.1.11` and therefore not inherited. `artifact-signing` prescribes keyless signing for container images and Helm charts and does not cover downloadable files such as ISOs and disk images. From the GitHub documentation: every release asset must be under 2 GiB, with no limit on total size [R1]; an immutable release locks its assets and its tag after publication and generates a release attestation [R2][R4][R5]; artifact attestations can be generated for arbitrary files and verified with `gh attestation verify` [R3].

Unestablished: how large the ISO and the raw disk image will be, which decides whether they fit under the 2 GiB limit; nothing has been built. Whether `gh attestation verify` works without a GitHub login was not looked up. The documentation quotes were taken from the fetched pages and not compared byte for byte with the originals.

Boundaries: `spec/deployment-targets/` owns which artifacts exist and where they are installed; `spec/distribution-requirements/` owns what the operating system provides, including the authenticity check of updates. This spec owns the path from a commit to a published, verifiable artifact. Release notes wording, version handling, and the branch model are owned by the inherited portfolio specs `project/release-automation` and `project/branching-model` and are not redefined here.

Readers: maintainers who write the workflows, reviewers of the release process, and authors of the installation documentation.

## Goals

- Every artifact a user can download was built by the project's CI from a known commit, and nobody can replace it afterwards.
- A user can prove with a short, documented check that a downloaded file is genuine before booting it.
- No long-lived signing secret exists that could be stolen.
- Releasing is a repeatable workflow run, not a manual procedure.

## Non-Goals

- Protection against a compromise of GitHub itself or of the signing infrastructure.
- Distribution through app stores, provider marketplaces, or package repositories.
- Signing for Secure Boot. That concerns the boot chain inside the image, not the download.
- Verification inside a cluster admission controller, which the portfolio signing spec covers for container deployments.
- Defining the wording of release notes.

## Requirements

### A. Build in CI

- **A1 MUST** build every delivery artifact in a GitHub Actions workflow of this repository and never on a developer machine.
- **A2 MUST** build on GitHub-hosted runners.
- **A3 MUST** build all artifacts of a release in one workflow run from one commit.
- **A4 MUST** pin every build input: the base image by digest, the container images by digest, and every action by commit SHA.
- **A5 SHOULD** run the same build without publishing on every change to the integration branch, so that a release is never the first build of its content.
- **A6 MUST** give workflows read-only permissions by default and grant more only to the job that needs it.

### B. Release

- **B1 MUST** publish the artifacts as assets of a GitHub release of this repository.
- **B2 MUST** prepare each release as a draft, attach all artifacts and their verification material to the draft, and publish it only when it is complete.
- **B3 MUST** publish through a release workflow that is started deliberately, and never by uploading files by hand.
- **B4 MUST** enable release immutability for the repository, so that assets and tag cannot change after publication.
- **B5 MUST** carry one version in the release tag, in every artifact file name, and in the system image identifier.
- **B6 MUST NOT** replace a published artifact; a defect is corrected by a new version.
- **B7 MUST** publish a release only after the verification that `spec/deployment-targets/` §G demands has passed for it.
- **B8 MUST** fail the release rather than publish it when an artifact exceeds the size limit of a release asset.
- **B9 MUST** state in the release notes the Kamerplanter version, the version of the base distribution, and the verified targets.

### C. Published set

- **C1 MUST** publish with every release the installer ISO, the raw disk image, a checksum file, the verification material, and the component lists.
- **C2 MUST** publish one checksum file that lists the SHA-256 digest of every artifact of the release.
- **C3 MUST** publish a component list for every artifact, as `spec/distribution-requirements/` §F requires.
- **C4 MUST** publish the system image under the same version in the project's container registry and reference it by digest, where the system is delivered or updated as a container image.
- **C5 MAY** compress artifacts, provided the documented installation path names the format.

### D. Signing

- **D1 MUST** sign every published artifact and the checksum file.
- **D2 MUST** sign keyless with the identity of the release workflow, obtained through the OIDC token of GitHub Actions.
- **D3 MUST NOT** store a long-lived private signing key in the repository, in its secrets, or on a runner.
- **D4 MUST** generate a build provenance attestation for every artifact that ties it to this repository, the workflow, and the commit.
- **D5 MUST** grant the permissions for signing and attesting only to the job that signs.
- **D6 MUST** sign only what the same workflow run has built.
- **D7 MUST** publish the signature material as release assets next to the artifacts.
- **D8 MUST** sign the system image in the container registry with the same identity, so that it can be checked like the downloaded artifacts. As long as the container tools on the appliance cannot check that identity, the system image additionally **MUST** carry a signature by an update key whose public part ships in the image, and the update check of `spec/distribution-requirements/` §B uses that key.

### E. Verification by the user

- **E1 MUST** document the verification in the README and in the notes of every release, with the exact commands.
- **E2 MUST** make the check of one downloaded artifact a single command.
- **E3 MUST** publish the expected signer: repository, workflow, and token issuer; the documented commands pin all three.
- **E4 MUST** make verification fail for a file that the release workflow of this repository did not build, including a rebuilt copy from a fork.
- **E5 SHOULD** allow verification without a GitHub account.
- **E6 SHOULD** allow verification without network access once the verification material has been downloaded.
- **E7 MUST** include the verification step in every documented installation path, before the artifact is written or booted.
- **E8 MUST** let an installed appliance show its version and system image identifier, so that the user can compare them with the release.

### F. Integrity of the release path

- **F1 MUST** restrict who can start the release workflow and who can create release tags.
- **F2 MUST NOT** run a job with signing permissions on code from a pull request or a fork.
- **F3 MUST** document how a faulty or compromised release is handled: mark it as withdrawn, publish a corrected version, and tell users which versions are affected.
- **F4 SHOULD** watch the public transparency log for signatures made with the project's identity that belong to no release run.

## Acceptance Criteria

The criteria roll several requirements together; every requirement stays normative on its own.

- [ ] A release is produced by one workflow run on GitHub-hosted runners, and every artifact of it names the same commit in its provenance (A1, A2, A3, D4).
- [ ] The workflow files reference every action by commit SHA and every image by digest, and no workflow grants write permissions at workflow level (A4, A6).
- [ ] The release contains the installer ISO, the raw disk image, one checksum file covering all artifacts, signature material for each, and a component list for each (C1, C2, C3, D1, D7).
- [ ] Tag, artifact file names, and the system image identifier of an appliance installed from the release carry the same version (B5, E8).
- [ ] An attempt to replace or delete an asset of a published release, or to move its tag, is refused by the platform (B4, B6).
- [ ] The release was a draft until all assets were attached, and the run that published it also recorded the passed target verification (B2, B3, B7).
- [ ] A build with an artifact above the asset size limit ends without a published release (B8).
- [ ] The repository and its settings contain no private signing key, and only the signing job holds the permissions to sign and attest (D2, D3, D5, D6).
- [ ] The documented command verifies a downloaded artifact of the release successfully (E1, E2, E3).
- [ ] The same command fails for a file with one changed byte and for an artifact built by the same workflow in a fork (E4).
- [ ] Verification succeeds on a machine without a GitHub login and, with the verification material at hand, without network access; where either is not possible, the documentation says so (E5, E6).
- [ ] Every installation guide for a target places the verification before the step that writes or boots the artifact (E7).
- [ ] The system image in the registry verifies against the same signer as the downloaded artifacts, and against the update key an installed appliance trusts (C4, D8).
- [ ] A pull request from a fork cannot start a job with signing permissions, and only named roles can start the release workflow or create a release tag (F1, F2).
- [ ] The release notes name the Kamerplanter version, the base distribution version, and the verified targets, and the procedure for a withdrawn release is documented (B9, F3).

## References

- Sources retrieved 2026-11-12.
- [R1] GitHub Docs, "About releases" (P): <https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases>
- [R2] GitHub Docs, "Immutable releases" (P): <https://docs.github.com/en/code-security/supply-chain-security/understanding-your-software-supply-chain/immutable-releases>
- [R3] GitHub Docs, "Using artifact attestations to establish provenance for builds" (P): <https://docs.github.com/en/actions/security-for-github-actions/using-artifact-attestations/using-artifact-attestations-to-establish-provenance-for-builds>
- [R4] GitHub Docs, "Verifying the integrity of a release" (P): <https://docs.github.com/en/code-security/how-tos/secure-your-supply-chain/secure-your-dependencies/verify-release-integrity>
- [R5] GitHub Docs, "Preventing changes to your releases" (P): <https://docs.github.com/en/code-security/how-tos/secure-your-supply-chain/establish-provenance-and-integrity/prevent-release-changes>

## Open Questions

- **Artifacts above 2 GiB.** B8 stops a release whose artifact exceeds the limit of a release asset [R1], but does not say what happens then. Nothing has been built, so the sizes are unknown. Stronger compression, splitting into parts, or a second download location are the options, and each changes the verification the user has to do.
- **Which verification tool.** Decided: the release workflow attaches a cosign signature bundle per artifact, verifiable without a GitHub account, and records a build provenance attestation verifiable with `gh attestation verify` (`docs/en/references/verify.md`). Whether `gh attestation verify` works without a GitHub login is still not looked up.
- **Signing specs outside the pinned hub release.** `artifact-signing` and `continuous-delivery` exist only on the hub's `develop` branch. Once a hub release contains them and the pin in `spec/.spec-config.yml` is raised, the rules here have to be compared with them. One point is already visible: `artifact-signing` restricts signing jobs to push events for release refs, while B2 and B3 here let the release workflow attach signed artifacts to a draft before publication.
- **Signing of files in the hub.** The hub's unreleased `artifact-signing` spec covers container images and Helm charts only. Whether the rules for downloadable files written here should move there is a question for the hub, not for this repository.
- **Branch setup.** The inherited `project/branching-model` makes `develop` the integration branch and `main` the release-presentation branch. This repository has only `main`, without commits; the branches and their protection have to be set up before A5 and B3 can be met.
- **Attestations on this repository.** The documentation page does not state for which plans and repository visibilities artifact attestations are available [R3]. It has to be confirmed for this repository before D4 can be relied on.
