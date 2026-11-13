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
| `SHA256SUMS` | SHA-256 checksums of all files of the release |
| `*.sigstore.json` | keyless signature bundles for the image and for `SHA256SUMS` |
| `kamerplanter-appliance-<version>-source-commit.txt` | the commit the image was built from |

The release workflow signs with its own identity; no private key exists. Each of the following checks fails for a file this repository's release workflow did not build, including a copy rebuilt in a fork.

## With cosign

Works without a GitHub account and, with the files downloaded, without network access to GitHub:

```bash
cosign verify-blob \
  --bundle kamerplanter-appliance-v0.1.0-x86_64.raw.xz.sigstore.json \
  --certificate-identity "https://github.com/nolte/kamerplanter-appliance/.github/workflows/release-publish.yml@refs/heads/develop" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  kamerplanter-appliance-v0.1.0-x86_64.raw.xz
```

## With the GitHub CLI

Checks the build provenance recorded at release time:

```bash
gh attestation verify kamerplanter-appliance-v0.1.0-x86_64.raw.xz \
  --repo nolte/kamerplanter-appliance \
  --signer-workflow nolte/kamerplanter-appliance/.github/workflows/release-publish.yml
```

Releases of this repository are immutable, so you can also confirm that a file is exactly the asset of a published release:

```bash
gh release verify-asset v0.1.0 kamerplanter-appliance-v0.1.0-x86_64.raw.xz --repo nolte/kamerplanter-appliance
```

## Checksums only

`sha256sum --check --ignore-missing SHA256SUMS` confirms that a download is complete. It does not prove where the file comes from unless `SHA256SUMS` itself was verified with one of the commands above.
