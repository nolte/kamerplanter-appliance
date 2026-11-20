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
# Usage: verify-release-assets.sh <system-image-ref@sha256:digest>
# Environment: GH_REPO (owner/name), GH_TOKEN.
set -euo pipefail

if [ $# -ne 1 ]; then
  echo "usage: $0 <system-image-ref>" >&2
  exit 2
fi
image_ref=$1
: "${GH_REPO:?GH_REPO is not set}"

identity="https://github.com/$GH_REPO/.github/workflows/release-publish.yml@refs/heads/develop"
issuer=https://token.actions.githubusercontent.com

cosign verify "$image_ref" --certificate-identity "$identity" \
  --certificate-oidc-issuer "$issuer" >/dev/null
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
    "$file"
  gh attestation verify "$file" --repo "$GH_REPO" \
    --signer-workflow "$GH_REPO/.github/workflows/release-publish.yml" \
    --source-ref refs/heads/develop --deny-self-hosted-runners
done
# Only now that SHA256SUMS is known to be this workflow's own.
sha256sum --check SHA256SUMS
