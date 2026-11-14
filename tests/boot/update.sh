#!/usr/bin/env bash
# Update and rollback tests (spec/update-and-rollback/). Runs inside the tool
# container (see build/in-tools.sh), after `task image:build`.
#
# The appliance under test is installed from a disk built the way a release
# builds it: the system image is pushed, signed, into a registry, and the disk
# is written from the pushed image with that registry as update source. Here
# the registry runs locally as registry.test:5000, reachable from the guest
# through QEMU's host address, and a key generated for the run signs.
#
#   tests/boot/update.sh [step ...]   (default: all steps)
#
# shellcheck disable=SC2329
# SC2329: the step_* functions are dispatched by name at the bottom.
set -uo pipefail

export DISK=.build/update/disk.raw
# shellcheck source=/dev/null
source "$(dirname "$0")/run.sh"
RESULTS=$OUT/update-results.tsv

BASE=${IMAGE_REF:-localhost/kamerplanter-appliance:poc}
WORK=.build/update
REGISTRY=registry.test:5000
CHANNEL=$REGISTRY/kamerplanter-appliance:stable
REGISTRY_IMAGE=docker.io/library/registry:3@sha256:82f6ff4a7f982960c8aa51617fea3aabc485df6e55cce80d22deb1de36f1bc3c
HEALTH_MINUTES=8
VOLUME=/var/lib/containers/storage/volumes/arangodb_data/_data

mkdir -p "$WORK"

# The registry, its signature attachments and its name, on the tool side.
setup_tools() {
    grep -q ' registry.test$' /etc/hosts || echo '127.0.0.1 registry.test' >>/etc/hosts
    mkdir -p /etc/containers/registries.conf.d /etc/containers/registries.d
    printf '[[registry]]\nlocation = "%s"\ninsecure = true\n' "$REGISTRY" \
        >/etc/containers/registries.conf.d/50-update-test.conf
    printf 'docker:\n  %s/kamerplanter-appliance:\n    use-sigstore-attachments: true\n' "$REGISTRY" \
        >/etc/containers/registries.d/update-test.yaml
    local key
    for key in trusted other; do
        [ -f "$WORK/$key.pub" ] && continue
        printf 'test-%s\n' "$key" >"$WORK/$key.pass"
        skopeo generate-sigstore-key --output-prefix "$WORK/$key" --passphrase-file "$WORK/$key.pass" >/dev/null
    done
}

registry_up() {
    podman container exists update-registry && return 0
    mkdir -p "$WORK/registry"
    podman run -d --rm --name update-registry --network host \
        -e REGISTRY_HTTP_ADDR=127.0.0.1:5000 -v "$PWD/$WORK/registry":/var/lib/registry \
        "$REGISTRY_IMAGE" >/dev/null
    for _ in $(seq 30); do curl -sf "http://$REGISTRY/v2/" >/dev/null && return 0; sleep 1; done
    echo "registry did not start" >&2
    return 1
}

registry_down() { podman stop -t 5 update-registry >/dev/null 2>&1 || true; }

# publish <local image> <key>: push signed as the release channel; prints the
# digest. The image goes through an OCI layout first, as in the release
# workflow: layers that local storage cannot reproduce byte for byte cannot be
# signed on the way out of it, but they can once they are files.
publish() {
    rm -rf "$WORK/oci"
    podman push --quiet --remove-signatures "$1" "oci:$WORK/oci" >/dev/null || return 1
    skopeo copy --quiet --dest-tls-verify=false \
        --sign-by-sigstore-private-key "$WORK/$2.private" --sign-passphrase-file "$WORK/$2.pass" \
        --digestfile "$WORK/digest" "oci:$WORK/oci" "docker://$CHANNEL" >/dev/null || return 1
    cat "$WORK/digest"
}

build_variant() {
    podman build --quiet -t "localhost/kamerplanter-appliance:test-$1" \
        --build-arg BASE="$BASE" --build-arg VARIANT="$1" tests/boot/variants >/dev/null
}

# The guest reaches the registry under the same name, trusts the run's key
# for it, and gets a short health budget and an immediate window spread.
prepare_guest() {
    guest "grep -q ' registry.test\$' /etc/hosts || echo '10.0.2.2 registry.test' >>/etc/hosts
        mkdir -p /etc/containers/registries.conf.d /etc/containers/registries.d /etc/kamerplanter-test \
            /etc/systemd/system/kamerplanter-update-apply.timer.d
        printf '[[registry]]\nlocation = \"$REGISTRY\"\ninsecure = true\n' >/etc/containers/registries.conf.d/50-update-test.conf
        printf 'docker:\n  $REGISTRY/kamerplanter-appliance:\n    use-sigstore-attachments: true\n' >/etc/containers/registries.d/update-test.yaml
        printf '[Timer]\nRandomizedDelaySec=0\n' >/etc/systemd/system/kamerplanter-update-apply.timer.d/90-test.conf
        echo UPDATE_HEALTH_TIMEOUT=$HEALTH_MINUTES >>/etc/kamerplanter/kamerplanter.env"
    guest "cat >/etc/kamerplanter-test/trusted.pub" <"$WORK/trusted.pub"
    guest "jq '.transports.docker[\"$REGISTRY/kamerplanter-appliance\"] = [{type: \"sigstoreSigned\",
        keyPath: \"/etc/kamerplanter-test/trusted.pub\", signedIdentity: {type: \"matchRepository\"}}]' \
        /usr/share/containers/policy.json >/etc/containers/policy.json && systemctl daemon-reload"
}

booted_digest() { guest "bootc status --format=json | jq -r .status.booted.image.imageDigest"; }
boot_id() { guest cat /proc/sys/kernel/random/boot_id 2>/dev/null; }
last_event() { guest "tail -n1 /var/lib/kamerplanter/update/log.jsonl"; }
has_event() { guest "grep -F '\"event\":\"$1\"' /var/lib/kamerplanter/update/log.jsonl | grep -qF '$2'"; }

# wait_reboot <boot id> <timeout>: until the guest runs with another boot id.
wait_reboot() {
    local start=$SECONDS id
    while ((SECONDS - start < $2)); do
        id=$(boot_id) && [ -n "$id" ] && [ "$id" != "$1" ] && { boot_id; return 0; }
        vm_alive || return 2
        sleep 10
    done
    return 1
}

# Until no update is being checked any more (health decided, or rollback done).
wait_decided() {
    local start=$SECONDS
    while ((SECONDS - start < $1)); do
        guest test ! -e /var/lib/kamerplanter/update/pending 2>/dev/null &&
            guest systemctl is-active -q kamerplanter-update-guard.service 2>/dev/null &&
            ! guest systemctl is-active -q kamerplanter-update-health.service 2>/dev/null &&
            return 0
        vm_alive || return 2
        sleep 10
    done
    return 1
}

fail() { diagnose "$1"; guest "cat /var/lib/kamerplanter/update/log.jsonl" >"$OUT/$1.update-log.txt" 2>&1; record "$1" FAIL - "$2"; }

# Push the image under test, build a disk from the pushed image, and boot it
# the first time without any network: every container image has to come
# with the disk.
step_install() {
    setup_tools
    # A fresh registry for every installation.
    podman rm --force update-registry >/dev/null 2>&1
    rm -rf "$WORK/registry"
    registry_up || { record u1 FAIL - "registry did not start"; return 1; }
    local digest
    digest=$(publish "$BASE" trusted) || { record u1 FAIL - "push of $BASE failed"; return 1; }
    podman pull --quiet "$REGISTRY/kamerplanter-appliance@$digest" >/dev/null
    echo "$digest" >"$WORK/base.digest"
    DISK_OUT=$DISK build/disk.sh "$REGISTRY/kamerplanter-appliance@$digest" "$CHANNEL" >"$OUT/u1.disk.log" 2>&1 ||
        { record u1 FAIL - "disk build failed, see u1.disk.log"; return 1; }
    new_overlay "$OUT/u1.qcow2"
    start_vm u1 bios virtio-scsi virtio off "$OUT/u1.qcow2"
    local secs
    if ! secs=$(wait_up "$FIRST_BOOT_TIMEOUT"); then
        fail u1 "first boot without network did not reach web UI and API"
        return 1
    fi
    record u1 PASS "${secs}s" "first boot without network; bound container images came with the disk (B4)"
    local source booted masked
    source=$(guest "bootc status --format=json | jq -r .spec.image.image")
    booted=$(booted_digest)
    masked=$(guest systemctl is-enabled bootc-fetch-apply-updates.timer 2>/dev/null)
    if [ "$source" = "$CHANNEL" ] && [ "$booted" = "$digest" ] && [ "$masked" = masked ] &&
        has_event install ok; then
        record u1-source PASS - "source $source, booted the pushed digest, bootc timer masked, install recorded (A2)"
    else
        fail u1-source "source=$source booted=$booted pushed=$digest bootc timer=$masked"
    fi
    stop_vm
}

# A healthy release is fetched, staged and activated in the maintenance
# window; the registry is gone before the window, so the new version starts
# from what was staged.
step_window() {
    [ -f "$OUT/u1.qcow2" ] || { record u2 SKIP - "needs the disk of the install step"; return 1; }
    registry_up
    vm_alive || start_vm u2 bios virtio-scsi virtio on "$OUT/u1.qcow2"
    wait_up "$REBOOT_TIMEOUT" >/dev/null || { fail u2 "appliance did not come up"; return 1; }
    prepare_guest
    guest "touch $VOLUME/WRITTEN_BEFORE_UPDATE"
    local variant
    for variant in next wrong broken; do
        build_variant "$variant" || { record u2 FAIL - "build of variant $variant failed"; return 1; }
    done
    local next
    next=$(publish localhost/kamerplanter-appliance:test-next trusted) || { record u2 FAIL - "push failed"; return 1; }
    echo "$next" >"$WORK/next.digest"
    guest kamerplanter-update fetch >"$OUT/u2.fetch.txt" 2>&1 || { fail u2 "fetch failed"; return 1; }
    [ "$(guest "bootc status --format=json | jq -r .status.staged.image.imageDigest")" = "$next" ] ||
        { fail u2 "the new release was not staged"; return 1; }
    registry_down
    local window id
    window=$(guest "date -d '+3 min' +%H:%M")
    guest "echo UPDATE_WINDOW=$window >>/etc/kamerplanter/kamerplanter.env && systemctl daemon-reload"
    guest kamerplanter-update status >"$OUT/u2.status-before.txt" 2>&1
    id=$(boot_id)
    wait_reboot "$id" 600 >/dev/null || { fail u2 "no reboot within the window at $window"; return 1; }
    wait_decided 1800 || { fail u2 "the health check did not decide"; return 1; }
    if [ "$(booted_digest)" = "$next" ] && has_event health ok &&
        guest test -d "/var/lib/kamerplanter/update/backup/$(cat "$WORK/base.digest")"; then
        record u2 PASS - "staged release activated in the window at $window without registry, healthy, data backed up (B4, C1, C3, C4, D2)"
    else
        fail u2 "not running the new release healthy after the window: $(last_event)"
    fi
    guest kamerplanter-update status >"$OUT/u2.status-after.txt" 2>&1
}

# A release signed with another key is not staged.
step_signature() {
    registry_up
    local wrong before
    before=$(booted_digest)
    wrong=$(publish localhost/kamerplanter-appliance:test-wrong other) || { record u3 FAIL - "push failed"; return 1; }
    if guest kamerplanter-update fetch >"$OUT/u3.fetch.txt" 2>&1; then
        fail u3 "fetch of a release signed with another key succeeded"
    elif [ "$(guest "bootc status --format=json | jq -r '.status.staged.image.imageDigest // empty'")" = "$wrong" ]; then
        fail u3 "the release signed with another key was staged"
    elif [ "$(booted_digest)" = "$before" ] && has_event fetch error; then
        record u3 PASS - "release signed with another key rejected and recorded (B3, E5)"
    else
        fail u3 "unexpected state: $(last_event)"
    fi
}

# Manual return to the previous version restores the data from before the
# update, and the release left is never applied again.
step_manual() {
    local id base next
    base=$(cat "$WORK/base.digest")
    next=$(cat "$WORK/next.digest")
    # Starts from the healthy update of the window step: next running, base
    # the previous version.
    if [ "$(booted_digest)" != "$next" ] ||
        [ "$(guest "bootc status --format=json | jq -r '.status.rollback.image.imageDigest // empty'")" != "$base" ]; then
        record u4 SKIP - "needs the healthy update of the window step"
        return 0
    fi
    guest "touch $VOLUME/WRITTEN_AFTER_UPDATE"
    id=$(boot_id)
    guest "kamerplanter-update rollback </dev/null" >"$OUT/u4.rollback.txt" 2>&1
    wait_reboot "$id" 600 >/dev/null || { fail u4 "no reboot after the rollback command"; return 1; }
    wait_up "$REBOOT_TIMEOUT" >/dev/null || { fail u4 "previous version did not come up"; return 1; }
    wait_decided 300
    if [ "$(booted_digest)" != "$base" ]; then
        fail u4 "booted $(booted_digest), not the previous version $base"
    elif guest test -e "$VOLUME/WRITTEN_AFTER_UPDATE" || ! guest test -e "$VOLUME/WRITTEN_BEFORE_UPDATE"; then
        fail u4 "the data was not restored to its state before the update"
    elif ! guest grep -qx "$next" /var/lib/kamerplanter/update/failed; then
        fail u4 "the release left is not marked as never to be applied again"
    else
        # The channel still carries it: it must not come back.
        publish localhost/kamerplanter-appliance:test-next trusted >/dev/null
        guest kamerplanter-update fetch >"$OUT/u4.fetch.txt" 2>&1
        if [ -n "$(guest "bootc status --format=json | jq -r '.status.staged.image.imageDigest // empty'")" ]; then
            fail u4 "the release left by rollback was staged again"
        else
            record u4 PASS - "manual rollback restored the previous version and its data; release not retried (F1, F2, F4, D3)"
        fi
    fi
}

# A release that writes to the data and never becomes healthy is rolled back
# on its own, with the data restored, and never tried again.
# auto_rollback <step> <vm name> <firmware>
auto_rollback() {
    local step=$1 base id
    base=$(booted_digest)
    registry_up
    publish localhost/kamerplanter-appliance:test-broken trusted >"$WORK/broken.digest" ||
        { record "$step" FAIL - "push failed"; return 1; }
    guest "rm -f $VOLUME/WRITTEN_BY_BROKEN"
    id=$(boot_id)
    guest kamerplanter-update apply-now >"$OUT/$step.apply.txt" 2>&1
    id=$(wait_reboot "$id" 900) || { fail "$step" "no reboot into the broken release"; return 1; }
    # Health budget, then the rollback reboot.
    wait_reboot "$id" $((HEALTH_MINUTES * 60 + 900)) >/dev/null ||
        { fail "$step" "no rollback reboot after the health budget"; return 1; }
    wait_up "$REBOOT_TIMEOUT" >/dev/null || { fail "$step" "previous version did not come up after rollback"; return 1; }
    wait_decided 300
    local broken
    broken=$(cat "$WORK/broken.digest")
    if [ "$(booted_digest)" != "$base" ]; then
        fail "$step" "booted $(booted_digest) after rollback, not $base"
    elif guest test -e "$VOLUME/WRITTEN_BY_BROKEN"; then
        fail "$step" "what the broken release wrote is still in the data"
    elif ! has_event health failed || ! has_event rollback "never applied again"; then
        fail "$step" "the record lacks the failed check or the rollback: $(last_event)"
    elif ! guest grep -qx "$broken" /var/lib/kamerplanter/update/failed; then
        fail "$step" "the broken release is not marked as never to be applied again"
    else
        guest kamerplanter-update fetch >"$OUT/$step.fetch.txt" 2>&1
        if [ -n "$(guest "bootc status --format=json | jq -r '.status.staged.image.imageDigest // empty'")" ]; then
            fail "$step" "the broken release was staged again"
        else
            record "$step" PASS - "$3: unhealthy release rolled back with data restored, recorded, not retried (D3, E1-E5)"
        fi
    fi
}

step_auto() { auto_rollback u5 u1 bios; stop_vm; }

# The same on UEFI, from a fresh install of the update disk.
step_uefi() {
    [ -f "$DISK" ] || { record u6 SKIP - "needs the disk of the install step"; return 1; }
    registry_up
    new_overlay "$OUT/u6.qcow2"
    start_vm u6 uefi virtio-scsi virtio on "$OUT/u6.qcow2"
    wait_up "$FIRST_BOOT_TIMEOUT" >/dev/null || { fail u6 "first boot on UEFI failed"; return 1; }
    prepare_guest
    auto_rollback u6 u6 uefi
    stop_vm
}

kill_vm 2>/dev/null
: >"$RESULTS"
steps=("$@")
[ ${#steps[@]} -gt 0 ] || steps=(install window signature manual auto uefi)
for step in "${steps[@]}"; do "step_$step" || break; done
kill_vm 2>/dev/null
registry_down
chmod -R a+rX "$OUT"
chmod 600 "$KEY"
echo
column -t -s $'\t' "$RESULTS"
grep -q FAIL "$RESULTS" && exit 1
exit 0
