---
title: Verifying a download
audience: [self-hoster, maintainer]
content_mode: how-to
track: user-docs
last_updated: 2026-11-13
---

# Verifying a download

Check every downloaded disk image before you write or boot it. A release carries, next to each image:

| File | Purpose |
|---|---|
| `kamerplanter-appliance-<version>-x86_64.raw.xz` | the compressed disk image |
| `SHA256SUMS` | SHA-256 checksums of the image and the source-commit file, by file name |
| `*.sigstore.json` | keyless signature bundles for the image and for `SHA256SUMS` |
| `kamerplanter-appliance-<version>-system-image.txt` | the system image in the registry that the disk image was written from, by digest |
| `kamerplanter-appliance-<version>-source-commit.txt` | the commit the image was built from |

The release workflow signs with its own identity; no private key exists. A signature proves that this repository's release workflow on `develop` built the file. It does not by itself say **which** release the file belongs to, because every release is signed with the same identity. Each way below therefore also binds the file to the version you want.

## With the GitHub CLI (recommended)

Releases of this repository are immutable. This confirms that the file is exactly the asset of the named release:

```bash
gh release verify-asset v0.1.0 kamerplanter-appliance-v0.1.0-x86_64.raw.xz --repo nolte/kamerplanter-appliance
```

The build provenance recorded at release time can be checked as well:

```bash
gh attestation verify kamerplanter-appliance-v0.1.0-x86_64.raw.xz \
  --repo nolte/kamerplanter-appliance \
  --signer-workflow nolte/kamerplanter-appliance/.github/workflows/release-publish.yml \
  --source-ref refs/heads/develop --deny-self-hosted-runners
```

## With cosign, without a GitHub account

Verify the signed `SHA256SUMS` of the release, then check the image against it. `SHA256SUMS` lists the image under its versioned name, so an image of another release fails the second step:

```bash
cosign verify-blob \
  --bundle SHA256SUMS.sigstore.json \
  --certificate-identity "https://github.com/nolte/kamerplanter-appliance/.github/workflows/release-publish.yml@refs/heads/develop" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  SHA256SUMS
sha256sum --check --ignore-missing SHA256SUMS
```

`SHA256SUMS` does not list the signature bundles: they are created after it and carry their own integrity.

## Checksums only

`sha256sum --check --ignore-missing SHA256SUMS` alone confirms that a download is complete. It does not prove where the file comes from unless `SHA256SUMS` itself was verified as above.

## The system image in the registry

Installed appliances update from `ghcr.io/nolte/kamerplanter-appliance`. Each released system image carries two signatures:

- one with the **update key**, which every appliance checks before it stages an update. Its public part is in the repository at `image/keys/system-image.pub` and on every appliance at `/usr/share/kamerplanter/keys/system-image.pub`. Appliances cannot check the workflow identity below yet, because the container tools they use only accept keys for now.
- one **keyless** signature by the release workflow, like the files above:

```bash
cosign verify ghcr.io/nolte/kamerplanter-appliance@sha256:<digest> \
  --certificate-identity "https://github.com/nolte/kamerplanter-appliance/.github/workflows/release-publish.yml@refs/heads/develop" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

Take the digest from the release's `-system-image.txt` file.
