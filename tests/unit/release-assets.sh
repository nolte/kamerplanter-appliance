#!/usr/bin/env bash
# Checks .github/scripts/verify-release-assets.sh, which release-publish.yml
# runs before it attaches freshly built files and before it reuses files a
# draft already carries (#113): it verifies the system image, and every disk
# image and SHA256SUMS by signature and provenance, against the exact
# identity of release-publish.yml on develop, passes every file after `--`,
# checks SHA256SUMS last, and fails on the first check that fails. cosign and
# gh are stubs that log their arguments and fail on request; sha256sum is the
# real one. Needs no network, no token and no release.
#
# Usage: tests/unit/release-assets.sh
set -uo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
script=$root/.github/scripts/verify-release-assets.sh

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

failures=0
expect() {  # expect NAME EXPECTED ACTUAL
    if [ "$2" = "$3" ]; then
        printf 'ok    %s\n' "$1"
    else
        printf 'FAIL  %s\n      expected: %s\n      actual:   %s\n' "$1" "$2" "$3"
        failures=$((failures + 1))
    fi
}
has() { case $2 in *"$1"*) echo yes ;; *) echo no ;; esac; }  # has NEEDLE HAYSTACK

repo=example/appliance
identity="https://github.com/$repo/.github/workflows/release-publish.yml@refs/heads/develop"
issuer=https://token.actions.githubusercontent.com
image="ghcr.io/$repo@sha256:$(printf '0%.0s' {1..64})"

# --- the stubs: one line per call in $STUB_LOG; a call exits 1 when
# $STUB_FAIL is the tool's name with its first or its last argument ---
mkdir -p "$work/bin"
for tool in cosign gh; do
    cat >"$work/bin/$tool" <<EOF
#!/usr/bin/env bash
printf '%s' "$tool" >>"\$STUB_LOG"
printf ' %s' "\$@" >>"\$STUB_LOG"
printf '\n' >>"\$STUB_LOG"
if [ "$tool \$1" = "\${STUB_FAIL-}" ] || [ "$tool \${!#}" = "\${STUB_FAIL-}" ]; then
    exit 1
fi
EOF
    chmod 0755 "$work/bin/$tool"
done

# new_release DIR FILE...: DIR holds the disk images FILE..., each with a
# bundle, and SHA256SUMS over them with its bundle.
new_release() {
    local dir=$1 file
    shift
    mkdir -p "$dir"
    for file in "$@"; do
        printf 'disk %s\n' "$file" >"$dir/$file"
        : >"$dir/$file.sigstore.json"
    done
    (cd "$dir" && { [ $# -eq 0 ] || sha256sum -- "$@"; } >SHA256SUMS)
    : >"$dir/SHA256SUMS.sigstore.json"
}

# run DIR [ARG...]: runs the script in DIR; sets status, out and log.
run() {
    local dir=$1
    shift
    export STUB_LOG=$work/log
    : >"$STUB_LOG"
    out=$(cd "$dir" && STUB_FAIL=${STUB_FAIL-} PATH="$work/bin:$PATH" GH_REPO=${REPO-$repo} \
        bash "$script" "$@" 2>&1)
    status=$?
    log=$(cat "$STUB_LOG")
}

# --- a complete release verifies ---
new_release "$work/good" kamerplanter-appliance-v1.0.0-x86_64.raw.xz
run "$work/good" "$image"
expect "a complete release verifies" 0 "$status"
expect "the system image is verified against the exact identity" yes \
    "$(has "cosign verify --certificate-identity $identity --certificate-oidc-issuer $issuer -- $image" "$log")"
for file in kamerplanter-appliance-v1.0.0-x86_64.raw.xz SHA256SUMS; do
    expect "$file: its signature bundle is verified, the file after --" yes \
        "$(has "cosign verify-blob --bundle $file.sigstore.json --certificate-identity $identity --certificate-oidc-issuer $issuer -- $file" "$log")"
    expect "$file: its provenance is verified against the exact identity, the file after --" yes \
        "$(has "gh attestation verify --repo $repo --cert-identity $identity --cert-oidc-issuer $issuer --source-ref refs/heads/develop --deny-self-hosted-runners -- $file" "$log")"
done
# gh matches --signer-workflow as ^https://github.com/<value>, without an
# end anchor: a workflow release-publish.yml-other.yml, or any ref of it,
# would match it.
expect "the provenance is never matched by --signer-workflow" no "$(has --signer-workflow "$log")"
expect "the checksums are checked" yes "$(has ": OK" "$out")"

# --- a file whose name starts with a dash is a file, not an option ---
new_release "$work/dash" -n.raw.xz
run "$work/dash" "$image"
expect "a disk image named -n.raw.xz verifies" 0 "$status"
expect "-n.raw.xz is passed after --" yes "$(has "-- -n.raw.xz" "$log")"

# --- every failing check fails the run, before the checksums are trusted ---
STUB_FAIL="cosign verify" run "$work/good" "$image"
expect "a system image without this workflow's signature fails" 1 "$status"
expect "  and nothing else is verified after it" 1 "$(grep -c . <<<"$log")"

STUB_FAIL="cosign kamerplanter-appliance-v1.0.0-x86_64.raw.xz" run "$work/good" "$image"
expect "a disk image whose signature does not verify fails" 1 "$status"
expect "  and its provenance is not looked at" no "$(has "gh attestation" "$log")"

new_release "$work/unattested" a.raw.xz
STUB_FAIL="cosign SHA256SUMS" run "$work/unattested" "$image"
expect "SHA256SUMS whose signature does not verify fails" 1 "$status"
expect "  and the checksums are not checked" no "$(has ": OK" "$out")"

# The disk image's bundle verifies, its provenance does not.
STUB_FAIL="gh a.raw.xz" run "$work/unattested" "$image"
expect "a disk image without this workflow's provenance fails" 1 "$status"
expect "  and the checksums are not checked" no "$(has ": OK" "$out")"

# --- the checksums are checked against the files ---
new_release "$work/changed" a.raw.xz b.raw.xz
printf 'changed\n' >"$work/changed/b.raw.xz"
run "$work/changed" "$image"
expect "a disk image that differs from SHA256SUMS fails" 1 "$status"
expect "  and names the file" yes "$(has "b.raw.xz: FAILED" "$out")"

# --- what is not a release ---
new_release "$work/empty"
run "$work/empty" "$image"
expect "a directory without a disk image fails" 1 "$status"
expect "  and says so" yes "$(has "no disk image" "$out")"

run "$work/good"
expect "a call without the system image reference is refused" 2 "$status"

REPO='' run "$work/good" "$image"
expect "a call without GH_REPO is refused" 1 "$status"
expect "  before anything is verified" "" "$log"

if [ "$failures" -gt 0 ]; then
    echo "$failures check(s) failed"
    exit 1
fi
echo "all checks passed"
