#!/usr/bin/env bash
# Verifies the files of a release in the current directory the way a user
# does (docs/en/references/verify.md), against the identity of this
# repository's release workflow on develop: SHA256SUMS against its files, the
# keyless signature and the build provenance of the disk images and of
# SHA256SUMS, and the keyless signature of the system image.
#
# release-publish.yml calls it before it attaches freshly built files and
# before it reuses files a draft already carries, so both paths pass the same
# checks.
#
# Every check pins the signer to the exact identity below. `gh attestation
# verify --signer-workflow` would not: it matches its value as the regular
# expression ^https://github.com/<value>, without an end anchor and with its
# dots unescaped, so a workflow whose path merely starts with
# release-publish.yml, or any ref of it, would pass; --cert-identity compares
# the certificate's whole SubjectAlternativeName instead. File arguments
# follow `--`, so a file name cannot be read as an option.
#
# Usage: verify-release-assets.sh <system-image-ref@sha256:digest>
# Environment: GH_REPO (owner/name), GH_TOKEN.
# tests/unit/release-assets.sh runs it on every pull request, with cosign and
# gh replaced by stubs.
set -euo pipefail

if [ $# -ne 1 ]; then
  echo "usage: $0 <system-image-ref>" >&2
  exit 2
fi
image_ref=$1
: "${GH_REPO:?GH_REPO is not set}"

identity="https://github.com/$GH_REPO/.github/workflows/release-publish.yml@refs/heads/develop"
issuer=https://token.actions.githubusercontent.com

cosign verify --certificate-identity "$identity" \
  --certificate-oidc-issuer "$issuer" -- "$image_ref" >/dev/null
shopt -s nullglob
disks=(*.raw.xz)
if [ ${#disks[@]} -eq 0 ]; then
  echo "::error::no disk image (*.raw.xz) in $PWD"
  exit 1
fi
for file in "${disks[@]}" SHA256SUMS; do
  cosign verify-blob --bundle "$file.sigstore.json" \
    --certificate-identity "$identity" \
    --certificate-oidc-issuer "$issuer" \
    -- "$file"
  gh attestation verify --repo "$GH_REPO" \
    --cert-identity "$identity" --cert-oidc-issuer "$issuer" \
    --source-ref refs/heads/develop --deny-self-hosted-runners \
    -- "$file"
done
# Only now that SHA256SUMS is known to be this workflow's own.
sha256sum --check -- SHA256SUMS
