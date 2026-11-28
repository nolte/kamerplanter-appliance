#!/usr/bin/env bash
# Checks the hardening of the provisioning data (spec/distribution-requirements/
# L15, L16): the scrub of cloud-init's copies
# (image/rootfs/usr/libexec/kamerplanter/scrub-cloud-init) on a fake cloud-init
# tree as cloud-init 26.2 leaves it, the units that run the scrub, load the
# metadata rules and load them again when they were removed, the network of
# every container (one in the host's network namespace would send as root and
# pass the rules), and the rules themselves as text. The script runs as it
# ships, in a sandbox (lib/sandbox.sh); it deletes and rewrites files only
# below a temporary directory. Needs no root, no cloud-init and no VM. The
# rules are loaded and tried in an isolated network namespace by
# tests/image/metadata-guard.sh.
#
# Usage: tests/unit/scrub.sh
set -uo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
image=$root/image/rootfs
# shellcheck source=tests/unit/lib/sandbox.sh
. "$root/tests/unit/lib/sandbox.sh"
set +e

work=$(mktemp -d)
trap 'chmod -R u+w "$work" 2>/dev/null; rm -rf "$work"' EXIT
# Everything the scrub prints, over all cases: no provisioned value may be in it.
all_output=$work/all-output
: >"$all_output"

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

# Provisioned values, each recognisable anywhere. quoted holds a quote and a
# backslash, so cloud-init's JSON files carry it escaped.
jwt=scrub-jwt-marker-$(printf 'a%.0s' {1..32})
fernet=scrub-fernet-marker-$(printf 'b%.0s' {1..24})=
quoted='scrub-"quoted"\marker-cccccccccccc'
quoted_json='scrub-\"quoted\"\\marker-cccccccccccc'
setting_secret=scrub-setting-salt-marker-$(printf 'd%.0s' {1..32})
markers=("$jwt" "$fernet" "$quoted" "$quoted_json" "$setting_secret")
url=https://kp.example.org/scrub-frontend-url

# --- the sandbox: cloud-init's files after a boot with provisioning data ---
# new_appliance: a fresh sandbox in SB with the scrub; no cloud-init state.
new_appliance() {
    SB=$(mktemp -d "$work/appliance.XXXXXX")
    sandbox_install "$SB" "$image" /usr/libexec/kamerplanter/scrub-cloud-init /usr/lib/kamerplanter/env.sh
    mkdir -p "$SB/var/lib/cloud/seed/nocloud" "$SB/var/log" "$SB/outside"
}
# combined_config: the combined cloud-config of a boot whose user-data holds
# the markers.
combined_config() {
    jq -cn --arg jwt "$jwt" --arg fernet "$fernet" --arg quoted "$quoted" --arg salt "$setting_secret" --arg url "$url" '{
        kamerplanter: {
            settings: {FRONTEND_URL: $url, LOG_PSEUDONYM_SALT: $salt},
            secrets: {JWT_SECRET_KEY: $jwt, FERNET_KEY: $fernet, TENANT_EXPORT_SIGNING_SECRET: $quoted}
        },
        system_info: {default_user: null}}'
}
user_data() {
    printf '#cloud-config\nhostname: kp\nkamerplanter:\n  settings:\n    FRONTEND_URL: %s\n    LOG_PSEUDONYM_SALT: %s\n  secrets:\n    JWT_SECRET_KEY: %s\n    FERNET_KEY: "%s"\n' \
        "$url" "$setting_secret" "$jwt" "$fernet"
}
# mime_user_data CLOUD_CONFIG: a MIME message as cloud-init keeps it in
# user-data.txt.i, with CLOUD_CONFIG as its one text/cloud-config part,
# base64-encoded.
mime_user_data() {
    local b='===============scrub-boundary=='
    printf 'Content-Type: multipart/mixed; boundary="%s"\nMIME-Version: 1.0\nNumber-Attachments: 1\n\n' "$b"
    printf -- '--%s\nContent-Type: text/cloud-config\nMIME-Version: 1.0\nContent-Disposition: attachment; filename="part-001"\nContent-Transfer-Encoding: base64\n\n' "$b"
    printf '%s' "$1" | base64 -w 76
    printf -- '\n--%s--\n' "$b"
}
# booted IID: what cloud-init 26.2 leaves after a boot of instance IID with
# that user-data, as the P1 spike found it, plus its record of the instance.
booted() {
    local lib=$SB/var/lib/cloud i=$SB/var/lib/cloud/instances/$1
    mkdir -p "$i/sem" "$i/scripts" "$i/handlers" "$lib/data" "$SB/run/cloud-init"
    user_data >"$i/user-data.txt"
    mime_user_data "$(user_data)" >"$i/user-data.txt.i"
    user_data >"$i/cloud-config.txt"
    # A pickle is binary: NUL bytes around the value.
    { printf '\x80\x05\x95\x00'; printf '%s' "$jwt"; printf '\x00\x00'; printf '%s' "$quoted"; printf '\x00\x94.'; } >"$i/obj.pkl"
    chmod 0400 "$i/obj.pkl"
    chmod 0600 "$i/user-data.txt" "$i/user-data.txt.i" "$i/cloud-config.txt"
    echo "DataSourceNoCloud: DataSourceNoCloud [seed=/dev/sr0]" >"$i/datasource"
    echo '{"version": 2, "ethernets": {"eth0": {"dhcp4": true}}}' >"$i/network-config.json"
    echo '#cloud-config' >"$i/vendor-data.txt"
    : >"$i/boot-finished"
    for s in config_ssh config_write_files config_users_groups consume_data; do echo "$s" >"$i/sem/$s"; done
    ln -sfn "$lib/instances/$1" "$lib/instance"
    echo "$1" >"$lib/data/instance-id"
    echo "$1" >"$lib/data/previous-instance-id"
    echo '{"v1": {"errors": []}}' >"$lib/data/result.json"
    # An error message that quotes a value, JSON-escaped.
    printf '{"v1": {"init": {"errors": ["value %s rejected"]}}}\n' "$quoted_json" >"$lib/data/status.json"
    combined_config >"$SB/run/cloud-init/combined-cloud-config.json"
    jq -cn --arg ud "$(user_data)" --arg iid "$1" '{v1: {platform: "nocloud", instance_id: $iid}, userdata: $ud}' \
        >"$SB/run/cloud-init/instance-data-sensitive.json"
    jq -cn --arg iid "$1" '{v1: {platform: "nocloud", instance_id: $iid}, userdata: "redacted for non-root user"}' \
        >"$SB/run/cloud-init/instance-data.json"
    chmod 0600 "$SB/run/cloud-init/combined-cloud-config.json" "$SB/run/cloud-init/instance-data-sensitive.json"
    echo "$1" >"$SB/run/cloud-init/.instance-id"
    {
        echo "2026-11-16 10:00:00,000 - util.py[DEBUG]: Writing to /var/lib/cloud/instances/$1/user-data.txt - wb: [600] 400 bytes"
        echo "2026-11-16 10:00:01,000 - handlers.py[DEBUG]: settings FRONTEND_URL=$url LOG_PSEUDONYM_SALT=$setting_secret"
        echo "2026-11-16 10:00:02,000 - schema.py[WARNING]: secret $jwt and $fernet in one line"
    } >>"$SB/var/log/cloud-init.log"
    chmod 0640 "$SB/var/log/cloud-init.log"
    printf 'Cloud-init v. 26.2 running\nrun: %s\n' "$jwt" >>"$SB/var/log/cloud-init-output.log"
}
run_scrub() {  # prints the exit status; the output is in $SB/out
    (
        bash "$SB/usr/libexec/kamerplanter/scrub-cloud-init" >"$SB/out" 2>&1
        echo "$?"
    )
    cat "$SB/out" >>"$all_output"
}
out() { cat "$SB/out"; }
# found DIR...: the files below DIR... that hold a marker, relative to SB;
# "none" when there is none. Symbolic links are not followed.
found() {
    local m hits=()
    for m in "${markers[@]}"; do
        while IFS= read -r f; do hits+=("${f#"$SB"/}"); done < <(grep -rlF -- "$m" "$@" 2>/dev/null)
    done
    if [ "${#hits[@]}" -eq 0 ]; then echo none; else printf '%s\n' "${hits[@]}" | sort -u | tr '\n' ' ' | sed 's/ $//'; fi
}
cloud_places() { echo "$SB/var/lib/cloud" "$SB/run/cloud-init" "$SB"/var/log/cloud-init*.log; }
mode() { stat -c %a "$1" 2>/dev/null; }
exists() { [ -e "$1" ] || [ -L "$1" ] && echo yes || echo no; }
# The cases that take a directory's mode away (chmod 0000, 0500) rest on the
# mode stopping this user. It does not stop root, or anyone who may override
# it (CAP_DAC_OVERRIDE): measured here, and those cases are skipped then, by
# name, instead of failing for a reason that is not the scrub's (#155). In CI
# a skipped case fails the file at its end (#173).
mkdir "$work/mode-probe"
chmod 0000 "$work/mode-probe"
if ls "$work/mode-probe" >/dev/null 2>&1; then modes_bind=''; else modes_bind=yes; fi
chmod 0700 "$work/mode-probe"
skips=0
skipped() {  # skipped NAME
    printf 'skip  %s (a mode does not stop this user)\n' "$1"
    skips=$((skips + 1))
}

# --- a boot with provisioning data: the copies go, the record stays (L15) ---
new_appliance
booted iid-1
# shellcheck disable=SC2046 # word splitting of the places is intended
expect "before the scrub, the markers are in cloud-init's places (the test can fail)" yes \
    "$([ "$(found $(cloud_places))" != none ] && echo yes)"
expect "a boot with provisioning data: the scrub succeeds" 0 "$(run_scrub)"
# shellcheck disable=SC2046
expect "no provisioned secret is left under /var/lib/cloud, /run/cloud-init or in cloud-init's logs" "none" \
    "$(found "$SB/var/lib/cloud/instances" "$SB/var/lib/cloud/data" "$SB/run/cloud-init" "$SB"/var/log/cloud-init*.log)"
i=$SB/var/lib/cloud/instances/iid-1
expect "the copies of the user-data are deleted: user-data.txt, user-data.txt.i, cloud-config.txt, obj.pkl" "no|no|no|no" \
    "$(exists "$i/user-data.txt")|$(exists "$i/user-data.txt.i")|$(exists "$i/cloud-config.txt")|$(exists "$i/obj.pkl")"
expect "the combined cloud-config and the sensitive instance data are deleted" "no|no" \
    "$(exists "$SB/run/cloud-init/combined-cloud-config.json")|$(exists "$SB/run/cloud-init/instance-data-sensitive.json")"
expect "cloud-init's record of the instance is kept: data/instance-id, the instance link, the semaphores" \
    "iid-1|$i|config_ssh config_users_groups config_write_files consume_data" \
    "$(cat "$SB/var/lib/cloud/data/instance-id")|$(readlink "$SB/var/lib/cloud/instance")|$(find "$i/sem" -mindepth 1 -maxdepth 1 -printf "%f\n" | sort | paste -sd " ")"
expect "the semaphores are untouched" "config_ssh|config_write_files|consume_data" \
    "$(cat "$i/sem/config_ssh")|$(cat "$i/sem/config_write_files")|$(cat "$i/sem/consume_data")"
expect "kept as well: previous-instance-id, datasource, network config, vendor-data, boot-finished, .instance-id, instance-data.json" \
    "iid-1|yes|yes|yes|yes|iid-1|nocloud" \
    "$(cat "$SB/var/lib/cloud/data/previous-instance-id")|$(exists "$i/datasource")|$(exists "$i/network-config.json")|$(exists "$i/vendor-data.txt")|$(exists "$i/boot-finished")|$(cat "$SB/run/cloud-init/.instance-id")|$(jq -r .v1.platform "$SB/run/cloud-init/instance-data.json")"
expect "the provisioning step's view of the next run is kept: instance-data.json still names the instance" iid-1 \
    "$(jq -r .v1.instance_id "$SB/run/cloud-init/instance-data.json")"
log=$SB/var/log/cloud-init.log
expect "the log keeps its lines and its mode, only the values are replaced" "3|640|yes|yes" \
    "$(wc -l <"$log")|$(mode "$log")|$(has "secret REDACTED and REDACTED in one line" "$(cat "$log")")|$(has "Writing to /var/lib/cloud/instances/iid-1/user-data.txt" "$(cat "$log")")"
expect "a secret key under settings: is replaced, an ordinary setting is not" "yes|yes" \
    "$(has "LOG_PSEUDONYM_SALT=REDACTED" "$(cat "$log")")|$(has "FRONTEND_URL=$url" "$(cat "$log")")"
expect "the output log of cloud-init is scrubbed too" "yes" "$(has "run: REDACTED" "$(cat "$SB/var/log/cloud-init-output.log")")"
expect "a value JSON-escaped in a file of cloud-init is replaced, the file stays JSON" "value REDACTED rejected" \
    "$(jq -r '.v1.init.errors[0]' "$SB/var/lib/cloud/data/status.json")"
expect "the scrub names what it rewrote and counts the deleted copies" "yes|yes" \
    "$(has "provisioned secrets replaced in $log" "$(out)")|$(has "copies of the provisioning data deleted: 6;" "$(out)")"

# --- the next boot with the source still attached: cloud-init stores it all
# again, the scrub deletes it again; nothing else changes (L15) ---
booted iid-1
expect "a reboot with the source attached: the copies are deleted again" "0|none|iid-1" \
    "$(run_scrub)|$(found "$SB/var/lib/cloud/instances" "$SB/var/lib/cloud/data" "$SB/run/cloud-init" "$SB"/var/log/cloud-init*.log)|$(cat "$SB/var/lib/cloud/data/instance-id")"
# Run again on the same boot: nothing left to do.
expect "a second run on the same boot: nothing to delete, nothing to replace" "0|yes" \
    "$(run_scrub)|$(has "deleted: 0; files with provisioned secrets replaced: 0" "$(out)")"

# --- copies of an earlier instance are deleted as well ---
new_appliance
booted iid-0
booted iid-1
expect "copies kept for an earlier instance are deleted too" "0|no|yes" \
    "$(run_scrub)|$(exists "$SB/var/lib/cloud/instances/iid-0/user-data.txt")|$(exists "$SB/var/lib/cloud/instances/iid-0/sem/config_ssh")"

# --- a boot without provisioning data: nothing happens (L4) ---
new_appliance
echo "untouched" >"$SB/var/log/messages"
before=$(cd "$SB" && find . -path ./out -prune -o -print | sort | md5sum)
expect "a boot without a source: the scrub succeeds and finds nothing" "0|yes" \
    "$(run_scrub)|$(has "deleted: 0; files with provisioned secrets replaced: 0" "$(out)")"
expect "a boot without a source: no file is created, changed or removed" "$before" \
    "$(cd "$SB" && find . -path ./out -prune -o -print | sort | md5sum)"
# Neither /run/cloud-init nor /var/lib/cloud exist at all.
rm -rf "$SB/var/lib/cloud" "$SB/run"
expect "no cloud-init directories at all: the scrub succeeds" 0 "$(run_scrub)"

# --- copies left by a boot that ended before the scrub, now without a
# source: the values are learned from the copies, the logs scrubbed, the
# copies deleted (#30) ---
new_appliance
booted iid-1
rm -rf "$SB/run"
expect "copies left from an earlier boot, without a source now: deleted" "0|no|no|iid-1" \
    "$(run_scrub)|$(exists "$SB/var/lib/cloud/instances/iid-1/user-data.txt")|$(exists "$SB/var/lib/cloud/instances/iid-1/obj.pkl")|$(cat "$SB/var/lib/cloud/data/instance-id")"
expect "copies left from an earlier boot: the logs are scrubbed with the values learned from them, and kept" "none|yes|yes" \
    "$(found "$SB"/var/log/cloud-init*.log)|$(has "secret REDACTED and REDACTED in one line" "$(cat "$SB/var/log/cloud-init.log")")|$(has "run: REDACTED" "$(cat "$SB/var/log/cloud-init-output.log")")"

# A copy of the cloud-config that cannot be read, but user-data.txt can: the
# values are learned from it, the logs are scrubbed and kept (#46). No
# user-data.txt.i, so that they can come from user-data.txt alone (#82).
new_appliance
booted iid-1
rm -rf "$SB/run"
printf 'kamerplanter: [unclosed\n' >"$SB/var/lib/cloud/instances/iid-1/cloud-config.txt"
rm -f "$SB/var/lib/cloud/instances/iid-1/user-data.txt.i"
cp "$SB/var/log/cloud-init.log" "$SB/var/log/cloud-init.log.1"
echo "untouched" >"$SB/var/log/messages"
rc=$(run_scrub)
expect "an unreadable cloud-config.txt, a readable user-data.txt: the logs are scrubbed and kept, rotated ones too, the copies go" "0|yes|yes|yes|yes|none|no|no" \
    "$rc|$(exists "$SB/var/log/cloud-init.log")|$(exists "$SB/var/log/cloud-init-output.log")|$(exists "$SB/var/log/cloud-init.log.1")|$(exists "$SB/var/log/messages")|$(found "$SB"/var/log/cloud-init*.log*)|$(exists "$SB/var/lib/cloud/instances/iid-1/cloud-config.txt")|$(exists "$SB/var/lib/cloud/instances/iid-1/user-data.txt")"
expect "an unreadable cloud-config.txt, a readable user-data.txt: the instance's secrets count as known" no \
    "$(has "no copy of the cloud-config can be read" "$(out)")"

# The same with user-data.txt compressed with gzip, as a source may supply it:
# it is decompressed and the values are learned from it alone (#82).
new_appliance
booted iid-1
rm -rf "$SB/run"
i=$SB/var/lib/cloud/instances/iid-1
printf 'kamerplanter: [unclosed\n' >"$i/cloud-config.txt"
rm -f "$i/user-data.txt.i"
user_data | gzip -c >"$i/user-data.txt"
rc=$(run_scrub)
expect "an unreadable cloud-config.txt, a gzip user-data.txt: its values are learned, the logs are scrubbed and kept, the copy goes" "0|yes|none|yes|no|no" \
    "$rc|$(exists "$SB/var/log/cloud-init.log")|$(found "$SB"/var/log/cloud-init*.log)|$(has "secret REDACTED and REDACTED in one line" "$(cat "$SB/var/log/cloud-init.log")")|$(has "no copy of the cloud-config can be read" "$(out)")|$(exists "$i/user-data.txt")"

# Only user-data.txt.i can be read, a MIME message as cloud-init writes it,
# its cloud-config part base64-encoded: the values are learned from that part.
new_appliance
booted iid-1
rm -rf "$SB/run"
i=$SB/var/lib/cloud/instances/iid-1
printf 'kamerplanter: [unclosed\n' >"$i/cloud-config.txt"
rm -f "$i/user-data.txt"
mime_user_data "$(user_data)" >"$i/user-data.txt.i"
cp "$SB/var/log/cloud-init.log" "$SB/var/log/cloud-init.log.1"
rc=$(run_scrub)
expect "only user-data.txt.i can be read (MIME, base64): the logs are scrubbed with its values and kept" "0|yes|yes|none|yes|no" \
    "$rc|$(exists "$SB/var/log/cloud-init.log")|$(exists "$SB/var/log/cloud-init.log.1")|$(found "$SB"/var/log/cloud-init*.log* "$i")|$(has "secret REDACTED and REDACTED in one line" "$(cat "$SB/var/log/cloud-init.log.1")")|$(exists "$i/user-data.txt.i")"
expect "only user-data.txt.i can be read: the instance's secrets count as known" no \
    "$(has "no copy of the cloud-config can be read" "$(out)")"

# No copy of the instance can be read: its values are unknown, so cloud-init's
# logs go, rotated ones included, and the error messages in its status and
# result are replaced; other logs and cloud-init's record stay (#46).
new_appliance
booted iid-1
rm -rf "$SB/run"
i=$SB/var/lib/cloud/instances/iid-1
printf 'kamerplanter: [unclosed\n' >"$i/cloud-config.txt"
printf '#cloud-config\nkamerplanter: [unclosed\n' >"$i/user-data.txt"
mime_user_data $'#cloud-config\nkamerplanter: [unclosed\n' >"$i/user-data.txt.i"
jq --arg m "schema warning near $jwt" '.v1.init.recoverable_errors = {WARNING: [$m]} | .v1.stage = null' \
    "$SB/var/lib/cloud/data/status.json" >"$SB/s" && mv "$SB/s" "$SB/var/lib/cloud/data/status.json"
jq -cn --arg m "failed on $jwt" '{v1: {datasource: "DataSourceNoCloud", errors: [$m], recoverable_errors: {}}}' \
    >"$SB/var/lib/cloud/data/result.json"
chmod 0644 "$SB/var/lib/cloud/data/status.json"
cp "$SB/var/log/cloud-init.log" "$SB/var/log/cloud-init.log.1"
echo "untouched" >"$SB/var/log/messages"
rc=$(run_scrub)
status=$SB/var/lib/cloud/data/status.json
expect "no copy can be read: cloud-init's logs are deleted, rotated ones too, other logs stay" "0|no|no|no|yes" \
    "$rc|$(exists "$SB/var/log/cloud-init.log")|$(exists "$SB/var/log/cloud-init-output.log")|$(exists "$SB/var/log/cloud-init.log.1")|$(exists "$SB/var/log/messages")"
expect "no copy can be read: no provisioned secret is left under /var/lib/cloud or /var/log" none \
    "$(found "$SB/var/lib/cloud" "$SB/var/log")"
expect "no copy can be read: the status stays JSON, its error messages replaced, their number and the rest kept" "1|REDACTED|REDACTED|null|644" \
    "$(jq '.v1.init.errors | length' "$status")|$(jq -r '.v1.init.errors[0]' "$status")|$(jq -r '.v1.init.recoverable_errors.WARNING[0]' "$status")|$(jq -c '.v1.stage' "$status")|$(mode "$status")"
expect "no copy can be read: the result stays JSON, its error messages replaced" "REDACTED|DataSourceNoCloud" \
    "$(jq -r '.v1.errors[0]' "$SB/var/lib/cloud/data/result.json")|$(jq -r '.v1.datasource' "$SB/var/lib/cloud/data/result.json")"
expect "no copy can be read: cloud-init's record of the instance is kept, the copies go" "iid-1|yes|no|no|no" \
    "$(cat "$SB/var/lib/cloud/data/instance-id")|$(exists "$i/sem/config_ssh")|$(exists "$i/cloud-config.txt")|$(exists "$i/user-data.txt")|$(exists "$i/user-data.txt.i")"
expect "no copy can be read: the scrub names the instance and says why the logs go" "yes|yes" \
    "$(has "$i: no copy of the cloud-config can be read; the provisioned secrets in it are not known, so cloud-init's logs are deleted" "$(out)")|$(has "error messages replaced in $status" "$(out)")"

# No copy can be read and a log cannot be deleted: it is named, the error
# messages are still replaced, the copies stay and the unit fails (#93).
new_appliance
booted iid-1
rm -rf "$SB/run"
i=$SB/var/lib/cloud/instances/iid-1
printf 'kamerplanter: [unclosed\n' >"$i/cloud-config.txt"
printf '#cloud-config\nkamerplanter: [unclosed\n' >"$i/user-data.txt"
mime_user_data $'#cloud-config\nkamerplanter: [unclosed\n' >"$i/user-data.txt.i"
if [ -z "$modes_bind" ]; then
    skipped "no copy can be read, a log cannot be deleted"
else
    chmod 0500 "$SB/var/log"
    rc=$(run_scrub)
    chmod 0700 "$SB/var/log"
    expect "no copy can be read, a log cannot be deleted: the scrub fails, names it, replaces the error messages, keeps the copies" "1|yes|yes|yes|yes|yes" \
        "$rc|$(has "$SB/var/log/cloud-init.log cannot be deleted; the provisioned secrets in it are not known" "$(out)")|$(has "error messages replaced in $SB/var/lib/cloud/data/status.json" "$(out)")|$(exists "$i/cloud-config.txt")|$(exists "$i/user-data.txt")|$(has "copies of the provisioning data are kept until the next boot retries" "$(out)")"
fi

# A status that is not JSON is left alone and named; nothing fails for it.
new_appliance
booted iid-1
rm -rf "$SB/run"
printf 'kamerplanter: [unclosed\n' >"$SB/var/lib/cloud/instances/iid-1/cloud-config.txt"
rm -f "$SB/var/lib/cloud/instances/iid-1/user-data.txt" "$SB/var/lib/cloud/instances/iid-1/user-data.txt.i"
printf '{"v1": {"init": {"errors": ["cut off' >"$SB/var/lib/cloud/data/status.json"
status_before=$(md5sum <"$SB/var/lib/cloud/data/status.json")
expect "no copy can be read, a status that is not JSON: left alone and named, the scrub succeeds" "0|$status_before|yes" \
    "$(run_scrub)|$(md5sum <"$SB/var/lib/cloud/data/status.json")|$(has "$SB/var/lib/cloud/data/status.json is not JSON" "$(out)")"

# A user-data.txt that is a shell script holds no cloud-config: it is read
# with nothing learned, and the instance does not count as unknown.
new_appliance
booted iid-1
rm -rf "$SB/run"
i=$SB/var/lib/cloud/instances/iid-1
rm -f "$i/cloud-config.txt" "$i/user-data.txt.i"
printf '#!/bin/sh\necho provisioned\n' >"$i/user-data.txt"
# Nothing is learned, so nothing is replaced: a status or a log that quoted a
# value would keep it, and the case would pin a secret left in place. Such a
# user-data holds none, so neither do its status and logs here (#82).
printf '{"v1": {"init": {"errors": ["a schema warning"]}}}\n' >"$SB/var/lib/cloud/data/status.json"
printf '2026-11-16 10:00:00,000 - util.py[DEBUG]: Writing to /var/lib/cloud/instances/iid-1/user-data.txt - wb: [600] 30 bytes\n' >"$SB/var/log/cloud-init.log"
printf 'Cloud-init v. 26.2 running\nprovisioned\n' >"$SB/var/log/cloud-init-output.log"
status_before=$(md5sum <"$SB/var/lib/cloud/data/status.json")
expect "a shell script as user-data: not unknown, the logs and the status are kept, the copy goes" "0|yes|yes|$status_before|no|no|none" \
    "$(run_scrub)|$(exists "$SB/var/log/cloud-init.log")|$(exists "$SB/var/log/cloud-init-output.log")|$(md5sum <"$SB/var/lib/cloud/data/status.json")|$(has "no copy of the cloud-config can be read" "$(out)")|$(exists "$i/user-data.txt")|$(found "$SB/var/lib/cloud" "$SB/var/log")"

# cloud-config.txt cannot be read and the user-data gives no cloud-config of
# its own, as an #include does: what cloud-config.txt holds is unknown, so the
# logs go.
new_appliance
booted iid-1
rm -rf "$SB/run"
i=$SB/var/lib/cloud/instances/iid-1
printf 'kamerplanter: [unclosed\n' >"$i/cloud-config.txt"
printf '#include\nhttps://kp.example.org/cloud-config\n' >"$i/user-data.txt"
rm -f "$i/user-data.txt.i"
expect "an unreadable cloud-config.txt beside an #include user-data: unknown, the logs go" "0|no|yes" \
    "$(run_scrub)|$(exists "$SB/var/log/cloud-init.log")|$(has "$i: no copy of the cloud-config can be read" "$(out)")"

# A cloud-config.txt that a crash left full of NUL bytes is not read as
# "nothing in it", and a Jinja template as user-data.txt gives no rendered
# values: the instance is unknown, the logs go.
new_appliance
booted iid-1
rm -rf "$SB/run"
i=$SB/var/lib/cloud/instances/iid-1
head -c 512 /dev/zero >"$i/cloud-config.txt"
{ echo '## template: jinja'; user_data; } >"$i/user-data.txt"
rm -f "$i/user-data.txt.i"
expect "a cloud-config.txt of NUL bytes beside a Jinja user-data: unknown, the logs go" "0|no|yes|none" \
    "$(run_scrub)|$(exists "$SB/var/log/cloud-init.log")|$(has "$i: no copy of the cloud-config can be read" "$(out)")|$(found "$SB/var/lib/cloud" "$SB/var/log")"

# A copy with a date and a tag JSON does not know is still read: the logs
# are scrubbed, not deleted.
new_appliance
booted iid-1
printf 'expires: 2026-12-01\nblob: !!binary aGVsbG8=\n' >>"$SB/var/lib/cloud/instances/iid-1/cloud-config.txt"
expect "a copy with a date and a binary tag: read, the logs are scrubbed and kept" "0|yes|none" \
    "$(run_scrub)|$(exists "$SB/var/log/cloud-init.log")|$(found "$SB"/var/log/cloud-init*.log)"

# Without the YAML module the copies cannot be read: the unit fails, nothing
# is deleted.
new_appliance
booted iid-1
mkdir -p "$SB/stub"
printf '#!/usr/bin/env bash\ncase "$*" in *"import yaml"*) exit 1 ;; esac\nexec %q "$@"\n' "$(command -v python3)" >"$SB/stub/python3"
chmod +x "$SB/stub/python3"
rc=$(PATH=$SB/stub:$PATH run_scrub)
expect "no YAML module: the scrub fails, says so, and deletes nothing" "1|yes|yes|yes" \
    "$rc|$(has "Python has no YAML module" "$(out)")|$(exists "$SB/var/log/cloud-init.log")|$(exists "$SB/var/lib/cloud/instances/iid-1/user-data.txt")"

# --- the scrub fails closed when the values cannot be learned (#76) ---
# stub_jq PATTERN: a jq in $SB/stub that fails when its arguments match
# PATTERN (a case pattern) and runs the real one otherwise.
stub_jq() {
    mkdir -p "$SB/stub"
    printf '#!/usr/bin/env bash\ncase "$*" in %s) exit 5 ;; esac\nexec %q "$@"\n' "$1" "$(command -v jq)" >"$SB/stub/jq"
    chmod +x "$SB/stub/jq"
}
# kept_copies: whether the copies of iid-1 and of this boot are all still there.
kept_copies() {
    local i=$SB/var/lib/cloud/instances/iid-1
    echo "$(exists "$i/user-data.txt")|$(exists "$i/user-data.txt.i")|$(exists "$i/cloud-config.txt")|$(exists "$i/obj.pkl")|$(exists "$SB/run/cloud-init/combined-cloud-config.json")|$(exists "$SB/run/cloud-init/instance-data-sensitive.json")"
}
all_kept="yes|yes|yes|yes|yes|yes"

# jq cannot run at all: nothing is learned, so nothing is deleted.
new_appliance
booted iid-1
stub_jq '*'
rc=$(PATH=$SB/stub:$PATH run_scrub)
expect "jq cannot run: the scrub fails, says so, deletes no copy and no log" "1|yes|$all_kept|yes|yes" \
    "$rc|$(has "jq cannot run; the provisioned secrets cannot be learned" "$(out)")|$(kept_copies)|$(exists "$SB/var/log/cloud-init.log")|$(exists "$SB/var/log/cloud-init-output.log")"
# Without copies and without a combined cloud-config there is nothing to
# learn: no jq is needed, the scrub succeeds.
new_appliance
stub_jq '*'
expect "jq cannot run, no provisioning data: the scrub succeeds" 0 "$(PATH=$SB/stub:$PATH run_scrub)"

# jq runs, but fails on the cloud-config it reads the secrets from: the
# values are not known, the copies are kept for the next boot to retry.
new_appliance
booted iid-1
stub_jq '*ARGS.positional*'
rc=$(PATH=$SB/stub:$PATH run_scrub)
expect "jq fails on the cloud-config: the scrub fails, names the files, keeps the copies" "1|yes|yes|$all_kept|yes" \
    "$rc|$(has "$SB/run/cloud-init/combined-cloud-config.json: jq cannot take the provisioned secrets out of it" "$(out)")|$(has "$SB/var/lib/cloud/instances/iid-1/user-data.txt: jq cannot take the provisioned secrets out of it" "$(out)")|$(kept_copies)|$(has "copies of the provisioning data are kept until the next boot retries" "$(out)")"
# The combined cloud-config is not JSON: its values are not known.
new_appliance
booted iid-1
printf '{"kamerplanter": {"secrets": {"JWT_SECRET_KEY": "%s"' "$jwt" >"$SB/run/cloud-init/combined-cloud-config.json"
rc=$(run_scrub)
expect "a combined cloud-config that is not JSON: the scrub fails and keeps the copies, the logs are still scrubbed" "1|$all_kept|none" \
    "$rc|$(kept_copies)|$(found "$SB"/var/log/cloud-init*.log)"

# jq fails on the search patterns: none is searched for, the copies stay.
new_appliance
booted iid-1
stub_jq '*tojson*'
rc=$(PATH=$SB/stub:$PATH run_scrub)
expect "jq fails on the search patterns: the scrub fails, says so, keeps the copies" "1|yes|$all_kept" \
    "$rc|$(has "the provisioned secrets cannot be made into search patterns (jq or Python failed, or Python made none)" "$(out)")|$(kept_copies)"

# --- each copy is read once (#76) ---
new_appliance
booted iid-1
mkdir -p "$SB/stub"
: >"$SB/reads"
printf '#!/usr/bin/env bash\ncase "$*" in *plain_types*) echo read >>%q ;; esac\nexec %q "$@"\n' "$SB/reads" "$(command -v python3)" >"$SB/stub/python3"
chmod +x "$SB/stub/python3"
rc=$(PATH=$SB/stub:$PATH run_scrub)
expect "each copy of the user-data is read once: three copies, three reads, and the scrub succeeds" "0|3" \
    "$rc|$(wc -l <"$SB/reads")"
# The same with an instance whose copies cannot be read: still one read each,
# and the instance is still found unknown.
new_appliance
booted iid-1
rm -rf "$SB/run"
i=$SB/var/lib/cloud/instances/iid-1
printf 'kamerplanter: [unclosed\n' >"$i/cloud-config.txt"
printf '#cloud-config\nkamerplanter: [unclosed\n' >"$i/user-data.txt"
mime_user_data $'#cloud-config\nkamerplanter: [unclosed\n' >"$i/user-data.txt.i"
mkdir -p "$SB/stub"
: >"$SB/reads"
printf '#!/usr/bin/env bash\ncase "$*" in *plain_types*) echo read >>%q ;; esac\nexec %q "$@"\n' "$SB/reads" "$(command -v python3)" >"$SB/stub/python3"
chmod +x "$SB/stub/python3"
rc=$(PATH=$SB/stub:$PATH run_scrub)
expect "no copy can be read: each is read once, the instance is unknown, the logs go" "0|3|yes|no" \
    "$rc|$(wc -l <"$SB/reads")|$(has "$i: no copy of the cloud-config can be read" "$(out)")|$(exists "$SB/var/log/cloud-init.log")"

# --- a place that is a symbolic link is not scrubbed, so the copies stay (#76) ---
# /var/log is a link: cloud-init's logs in it are not scrubbed.
new_appliance
booted iid-1
mv "$SB/var/log" "$SB/outside/log"
ln -sfn "$SB/outside/log" "$SB/var/log"
log_before=$(md5sum <"$SB/outside/log/cloud-init.log")
rc=$(run_scrub)
expect "/var/log as a link: the scrub fails, says so, keeps the copies, the logs behind it are untouched" "1|yes|$all_kept|$log_before" \
    "$rc|$(has "$SB/var/log is a symbolic link; the provisioned secrets in it are not scrubbed" "$(out)")|$(kept_copies)|$(md5sum <"$SB/outside/log/cloud-init.log")"
expect "/var/log as a link: the other places are still scrubbed" none \
    "$(found "$SB/var/lib/cloud/data")"
# /var/log is a link and no copy can be read: the logs cannot be deleted
# either, so the copies stay.
new_appliance
booted iid-1
rm -rf "$SB/run"
i=$SB/var/lib/cloud/instances/iid-1
printf 'kamerplanter: [unclosed\n' >"$i/cloud-config.txt"
printf '#cloud-config\nkamerplanter: [unclosed\n' >"$i/user-data.txt"
mime_user_data $'#cloud-config\nkamerplanter: [unclosed\n' >"$i/user-data.txt.i"
mv "$SB/var/log" "$SB/outside/log"
ln -sfn "$SB/outside/log" "$SB/var/log"
rc=$(run_scrub)
expect "/var/log as a link, no copy can be read: the scrub fails, the logs behind it and the copies stay" "1|yes|yes|yes" \
    "$rc|$(exists "$SB/outside/log/cloud-init.log")|$(exists "$i/cloud-config.txt")|$(exists "$i/user-data.txt")"
# /run/cloud-init is a link: the files in it are not scrubbed.
new_appliance
booted iid-1
mv "$SB/run/cloud-init" "$SB/outside/run"
ln -sfn "$SB/outside/run" "$SB/run/cloud-init"
rc=$(run_scrub)
expect "/run/cloud-init as a link: the scrub fails, says so, keeps the copies, the files behind it are untouched" "1|yes|yes|yes|yes" \
    "$rc|$(has "$SB/run/cloud-init is a symbolic link; the copies of the provisioning data in it are neither read nor deleted" "$(out)")|$(exists "$SB/var/lib/cloud/instances/iid-1/user-data.txt")|$(exists "$SB/outside/run/instance-data-sensitive.json")|$([ "$(found "$SB/outside/run")" != none ] && echo yes)"
# The same without provisioning data: what lies behind the link is neither
# read nor known, so it fails all the same (#93), and the file behind it is
# untouched.
new_appliance
mkdir -p "$SB/outside/run"
echo '{"userdata": "outside"}' >"$SB/outside/run/instance-data-sensitive.json"
echo '{}' >"$SB/outside/run/combined-cloud-config.json"
mkdir -p "$SB/run"
ln -sfn "$SB/outside/run" "$SB/run/cloud-init"
rc=$(run_scrub)
expect "/run/cloud-init as a link, no provisioning data: the scrub fails, names it once, the files behind it are untouched" "1|1|yes|yes" \
    "$rc|$(grep -cF "$SB/run/cloud-init is a symbolic link" "$SB/out")|$(exists "$SB/outside/run/instance-data-sensitive.json")|$(exists "$SB/outside/run/combined-cloud-config.json")"

# A file outside the logs that starts like a compressed one is searched as it
# is, never deleted.
new_appliance
booted iid-1
printf '\x1f\x8bnot really gzip' >"$SB/var/lib/cloud/data/instance-id.bak"
expect "a non-log file that looks compressed is kept" "0|yes" \
    "$(run_scrub)|$(exists "$SB/var/lib/cloud/data/instance-id.bak")"

# --- rotated logs (#30): plain ones are scrubbed, compressed ones that hold a
# value or cannot be read are deleted, the others kept ---
new_appliance
booted iid-1
log=$SB/var/log/cloud-init.log
cp "$log" "$SB/var/log/cloud-init.log.1"
cp "$log" "$SB/var/log/cloud-init-output.log-20261116"
gzip -c "$log" >"$SB/var/log/cloud-init.log.2.gz"
printf 'nothing secret\n' | gzip -c >"$SB/var/log/cloud-init.log.3.gz"
printf 'nothing secret\n' | xz -c >"$SB/var/log/cloud-init.log.4.xz"
cp "$log" "$SB/var/log/cloud-init.log.5" && bzip2 "$SB/var/log/cloud-init.log.5"
printf '\x1f\x8bnot really gzip' >"$SB/var/log/cloud-init.log.6.gz"
rc=$(run_scrub)
expect "rotated logs: the scrub succeeds, plain rotated logs are scrubbed and kept" "0|none|yes|yes" \
    "$rc|$(found "$SB/var/log/cloud-init.log.1" "$SB/var/log/cloud-init-output.log-20261116")|$(has "secret REDACTED and REDACTED in one line" "$(cat "$SB/var/log/cloud-init.log.1")")|$(exists "$SB/var/log/cloud-init-output.log-20261116")"
expect "rotated logs: compressed ones with a value or unreadable are deleted, the others kept" "no|yes|yes|no|no" \
    "$(exists "$SB/var/log/cloud-init.log.2.gz")|$(exists "$SB/var/log/cloud-init.log.3.gz")|$(exists "$SB/var/log/cloud-init.log.4.xz")|$(exists "$SB/var/log/cloud-init.log.5.bz2")|$(exists "$SB/var/log/cloud-init.log.6.gz")"
expect "rotated logs: the scrub names the deleted compressed logs and counts them" "yes|yes" \
    "$(has "deleted $SB/var/log/cloud-init.log.2.gz: a compressed file that holds provisioned secrets or cannot be read" "$(out)")|$(has "compressed logs with provisioned secrets deleted: 3" "$(out)")"

# --- seed files are the source, not a copy: kept, and warned about (L3, L20) ---
new_appliance
booted iid-1
user_data >"$SB/var/lib/cloud/seed/nocloud/user-data"
echo 'instance-id: iid-1' >"$SB/var/lib/cloud/seed/nocloud/meta-data"
seed_before=$(md5sum <"$SB/var/lib/cloud/seed/nocloud/user-data")
expect "seed files: the scrub succeeds and leaves them as they are" "0|$seed_before|yes" \
    "$(run_scrub)|$(md5sum <"$SB/var/lib/cloud/seed/nocloud/user-data")|$(exists "$SB/var/lib/cloud/seed/nocloud/meta-data")"
expect "seed files: the warning names the file, the copies are gone" "yes|none" \
    "$(has "warning: the seed file $SB/var/lib/cloud/seed/nocloud/user-data holds provisioned secrets" "$(out)")|$(found "$SB/var/lib/cloud/instances" "$SB/run/cloud-init" "$SB"/var/log/cloud-init*.log)"
# A directory among the seed files whose file system cannot be told (stat
# fails on it; the stubs of stat are below, with the other cases of a file
# system): one more warning, and nothing fails.
new_appliance
booted iid-1
user_data >"$SB/var/lib/cloud/seed/nocloud/user-data"
mkdir -p "$SB/stub"
# shellcheck disable=SC2016 # expanded by the stub, not here
printf '#!/usr/bin/env bash\ncase "${!#}" in */seed/nocloud) exit 1 ;; esac\nexec %q "$@"\n' "$(command -v stat)" >"$SB/stub/stat"
chmod +x "$SB/stub/stat"
rc=$(PATH=$SB/stub:$PATH run_scrub)
expect "seed files: a directory whose file system cannot be told is warned about, the scrub succeeds" "0|1|none" \
    "$rc|$(grep -cF "warning: the file system of $SB/var/lib/cloud/seed/nocloud cannot be told; whether every seed file in it is looked into is not known" "$SB/out")|$(found "$SB/var/lib/cloud/instances" "$SB/run/cloud-init" "$SB"/var/log/cloud-init*.log)"

# --- symbolic links are never followed ---
# A link that is no copy and in no place the scrub enters: the file it points
# to keeps its content, the scrub succeeds.
new_appliance
booted iid-1
echo "outside $jwt" >"$SB/outside/target"
ln -sfn "$SB/outside/target" "$SB/var/lib/cloud/instances/iid-1/vendor-cloud-config.txt"
ln -sfn "$SB/outside/target" "$SB/run/cloud-init/instance-data-sensitive.json.link"
rc=$(run_scrub)
expect "links into other places: the files they point to keep their content, the scrub succeeds" "0|outside $jwt|no" \
    "$rc|$(cat "$SB/outside/target")|$(exists "$SB/var/lib/cloud/instances/iid-1/user-data.txt")"
# An instance directory that is a link: the copies behind it are neither read
# nor deleted, so it is named, the copies stay and the scrub fails (#93).
new_appliance
booted iid-1
mkdir -p "$SB/outside/dir"
echo "outside $jwt" >"$SB/outside/dir/user-data.txt"
ln -sfn "$SB/outside/dir" "$SB/var/lib/cloud/instances/linked"
rc=$(run_scrub)
expect "links: an instance directory as a link is not entered, named, the copies are kept, the scrub fails" "1|outside $jwt|yes|$all_kept" \
    "$rc|$(cat "$SB/outside/dir/user-data.txt")|$(has "$SB/var/lib/cloud/instances/linked is a symbolic link; the copies of the provisioning data in it are neither read nor deleted" "$(out)")|$(kept_copies)"
# A copy that is a link, in an instance directory or in /run/cloud-init: not
# read, deleted or rewritten through it; named, the copies stay (#93).
new_appliance
booted iid-1
i=$SB/var/lib/cloud/instances/iid-1
mv "$i/cloud-config.txt" "$SB/outside/cloud-config.txt"
ln -sfn "$SB/outside/cloud-config.txt" "$i/cloud-config.txt"
outside_before=$(md5sum <"$SB/outside/cloud-config.txt")
rc=$(run_scrub)
expect "links: a copy in an instance directory as a link is named, the file behind it untouched, the copies kept, the scrub fails" "1|$outside_before|yes|$all_kept" \
    "$rc|$(md5sum <"$SB/outside/cloud-config.txt")|$(has "$i/cloud-config.txt is a symbolic link; the copy of the provisioning data behind it is neither read nor deleted" "$(out)")|$(kept_copies)"
new_appliance
booted iid-1
mv "$SB/run/cloud-init/instance-data-sensitive.json" "$SB/outside/instance-data-sensitive.json"
ln -sfn "$SB/outside/instance-data-sensitive.json" "$SB/run/cloud-init/instance-data-sensitive.json"
rc=$(run_scrub)
expect "links: a copy in /run/cloud-init as a link is named, the file behind it kept, the copies kept, the scrub fails" "1|yes|yes|$all_kept" \
    "$rc|$(exists "$SB/outside/instance-data-sensitive.json")|$(has "$SB/run/cloud-init/instance-data-sensitive.json is a symbolic link; the copy of the provisioning data behind it is neither read nor deleted" "$(out)")|$(kept_copies)"
# /var/lib/cloud/data as a link: cloud-init's status and result behind it are
# not scrubbed, so when there is something to scrub the copies stay (#93).
new_appliance
booted iid-1
mv "$SB/var/lib/cloud/data" "$SB/outside/data"
ln -sfn "$SB/outside/data" "$SB/var/lib/cloud/data"
status_before=$(md5sum <"$SB/outside/data/status.json")
rc=$(run_scrub)
expect "links: /var/lib/cloud/data as a link is named, the status behind it untouched, the copies kept, the scrub fails" "1|$status_before|yes|$all_kept" \
    "$rc|$(md5sum <"$SB/outside/data/status.json")|$(has "$SB/var/lib/cloud/data is a symbolic link; the provisioned secrets in cloud-init's status and result behind it are not scrubbed" "$(out)")|$(kept_copies)"
# The status in it as a link: the same.
new_appliance
booted iid-1
mv "$SB/var/lib/cloud/data/status.json" "$SB/outside/status.json"
ln -sfn "$SB/outside/status.json" "$SB/var/lib/cloud/data/status.json"
status_before=$(md5sum <"$SB/outside/status.json")
rc=$(run_scrub)
expect "links: the status in /var/lib/cloud/data as a link is named, the file behind it untouched, the copies kept, the scrub fails" "1|$status_before|yes|$all_kept" \
    "$rc|$(md5sum <"$SB/outside/status.json")|$(has "$SB/var/lib/cloud/data/status.json is a symbolic link; the provisioned secrets behind it are not scrubbed" "$(out)")|$(kept_copies)"
# The same without provisioning data: nothing to scrub, the link is only named.
new_appliance
mkdir -p "$SB/outside/data"
ln -sfn "$SB/outside/data" "$SB/var/lib/cloud/data"
expect "links: /var/lib/cloud/data as a link, no provisioning data: the scrub succeeds and names it once" "0|1" \
    "$(run_scrub)|$(grep -cF "$SB/var/lib/cloud/data is a symbolic link; it is not entered" "$SB/out")"
new_appliance
booted iid-1
echo "outside $jwt" >"$SB/outside/log"
rm -f "$SB/var/log/cloud-init.log"
ln -sfn "$SB/outside/log" "$SB/var/log/cloud-init.log"
# What lies behind it keeps the values, so the copies are kept and the scrub
# fails (#76).
expect "links: a log that is a link is not rewritten through it, the copies are kept, the scrub fails and names it" "1|outside $jwt|yes|yes" \
    "$(run_scrub)|$(cat "$SB/outside/log")|$(exists "$SB/var/lib/cloud/instances/iid-1/user-data.txt")|$(has "$SB/var/log/cloud-init.log is a symbolic link; the provisioned secrets behind it are not scrubbed" "$(out)")"
new_appliance
mkdir -p "$SB/outside/cloud/instances/iid-1"
echo "outside $jwt" >"$SB/outside/cloud/instances/iid-1/user-data.txt"
rm -rf "$SB/var/lib/cloud"
ln -sfn "$SB/outside/cloud" "$SB/var/lib/cloud"
mkdir -p "$SB/run/cloud-init"
combined_config >"$SB/run/cloud-init/combined-cloud-config.json"
# What lies behind the link keeps the values, so the copies are kept and the
# scrub fails (#76).
expect "links: /var/lib/cloud as a link is not scrubbed, says so once, keeps the combined cloud-config and fails" "1|yes|1|yes|yes" \
    "$(run_scrub)|$(exists "$SB/outside/cloud/instances/iid-1/user-data.txt")|$(grep -cF "$SB/var/lib/cloud is a symbolic link" "$SB/out")|$(has "$SB/var/lib/cloud is a symbolic link; the copies of the provisioning data in it are neither read nor deleted" "$(out)")|$(exists "$SB/run/cloud-init/combined-cloud-config.json")"
# Without a combined cloud-config nothing is learned at all, yet copies with
# values can lie behind the link: the scrub fails all the same.
rm -f "$SB/run/cloud-init/combined-cloud-config.json"
expect "links: /var/lib/cloud as a link, nothing learned: the scrub still fails and names it" "1|yes" \
    "$(run_scrub)|$(has "$SB/var/lib/cloud is a symbolic link; the copies of the provisioning data in it are neither read nor deleted" "$(out)")"

# --- a place that could not be read is not taken for an empty one (#119) ---
# An instance directory that cannot be searched: find fails on it, and its
# exit status is not lost. The place is named (find names the directory
# itself), the copies stay, the logs are still scrubbed, the scrub fails.
new_appliance
booted iid-1
locked=$SB/var/lib/cloud/instances/iid-locked
mkdir -p "$locked"
user_data >"$locked/user-data.txt"
if [ -z "$modes_bind" ]; then
    skipped "a search that fails: an instance directory that cannot be read"
else
    chmod 0000 "$locked"
    rc=$(run_scrub)
    chmod 0700 "$locked"
    expect "a search that fails: an instance directory that cannot be read is named, the copies are kept, the scrub fails" "1|yes|yes|$all_kept|yes" \
        "$rc|$(has "$SB/var/lib/cloud/instances cannot be searched (see find's message); what could not be read there is neither scrubbed nor deleted" "$(out)")|$(has "iid-locked" "$(out)")|$(kept_copies)|$(exists "$locked/user-data.txt")"
    # One directory that cannot be read fails every search that meets it: of
    # the instances, of /var/lib/cloud, of all the files. The scrub names the
    # cause once, by the first place; find names the directory each time
    # (#155).
    expect "a search that fails: the scrub names the one cause once, by its first place, the logs are scrubbed all the same" "1|1|none" \
        "$(grep -cF "cannot be searched (see find's message)" "$SB/out")|$(grep -cF "$SB/var/lib/cloud/instances cannot be searched" "$SB/out")|$(found "$SB"/var/log/cloud-init*.log)"
fi
# A second directory that cannot be read, outside the instances, is another
# cause: /var/lib/cloud is named as well, once, as failing outside the place
# that is named already (#173).
new_appliance
booted iid-1
locked=$SB/var/lib/cloud/instances/iid-locked
other_locked=$SB/var/lib/cloud/data/locked
mkdir -p "$locked" "$other_locked"
user_data >"$locked/user-data.txt"
if [ -z "$modes_bind" ]; then
    skipped "a search that fails: two directories that cannot be read, in two places"
else
    chmod 0000 "$locked" "$other_locked"
    rc=$(run_scrub)
    chmod 0700 "$locked" "$other_locked"
    expect "a search that fails: two directories that cannot be read, in two places: each place is named once, the copies are kept, the scrub fails" "1|2|1|1|$all_kept" \
        "$rc|$(grep -cF "cannot be searched" "$SB/out")|$(grep -cF "$SB/var/lib/cloud/instances cannot be searched (see find's message); what could not be read there is neither scrubbed nor deleted" "$SB/out")|$(grep -cF "$SB/var/lib/cloud cannot be searched outside $SB/var/lib/cloud/instances either (see find's message); what could not be read there is neither scrubbed nor deleted" "$SB/out")|$(kept_copies)"
fi
# The same without anything learned: the directory may hold copies, so the
# scrub fails all the same.
new_appliance
locked=$SB/var/lib/cloud/instances/iid-locked
mkdir -p "$locked"
user_data >"$locked/user-data.txt"
if [ -z "$modes_bind" ]; then
    skipped "a search that fails, nothing learned"
else
    chmod 0000 "$locked"
    rc=$(run_scrub)
    chmod 0700 "$locked"
    expect "a search that fails, nothing learned: the scrub still fails, names the place and keeps the copy" "1|yes|yes" \
        "$rc|$(has "$SB/var/lib/cloud/instances cannot be searched" "$(out)")|$(exists "$locked/user-data.txt")"
fi
# A search that fails only when the files are searched (scanned): that search
# goes through every place and does not say which one failed, so each place is
# asked (#184).
# stub_find COMMAND: a find in $SB/stub that runs COMMAND, with the place in
# $1, before the real find when that searches the files of /run/cloud-init, as
# only the search of the files does; COMMAND fails the search by setting rc.
stub_find() {
    mkdir -p "$SB/stub"
    # shellcheck disable=SC2016 # expanded by the stub, not here
    printf '#!/usr/bin/env bash\nrc=0\ncase "$1| $* " in */run/cloud-init/"|"*" -type f "*) %s ;; esac\n%q "$@" || rc=$?\nexit "$rc"\n' \
        "$1" "$(command -v find)" >"$SB/stub/find"
    chmod +x "$SB/stub/find"
}
# A directory in /run/cloud-init that cannot be read from then on: the one
# place that still fails is named, once, though the files are searched twice;
# the logs are scrubbed all the same, the copies stay.
new_appliance
booted iid-1
if [ -z "$modes_bind" ]; then
    skipped "a search that fails only when the files are searched"
else
    # shellcheck disable=SC2016 # expanded by the stub, not here
    stub_find 'mkdir -p "$1locked" && chmod 0000 "$1locked"'
    rc=$(PATH=$SB/stub:$PATH run_scrub)
    chmod 0700 "$SB/run/cloud-init/locked"
    expect "a search that fails only when the files are searched: the place that fails is named once and no other, the logs are scrubbed, the copies are kept, the scrub fails" "1|1|1|no|$all_kept|none" \
        "$rc|$(grep -cF "cannot be searched (see find's message)" "$SB/out")|$(grep -cF "$SB/run/cloud-init cannot be searched (see find's message); what could not be read there is neither scrubbed nor deleted" "$SB/out")|$(has "cloud-init's files and logs cannot be searched" "$(out)")|$(kept_copies)|$(found "$SB"/var/log/cloud-init*.log)"
fi
# The search of the files fails and no place fails when asked afterwards: the
# failure is named without a place, once, though the files are searched twice;
# the copies stay.
new_appliance
booted iid-1
stub_find 'echo "find: a search that fails" >&2; rc=1'
rc=$(PATH=$SB/stub:$PATH run_scrub)
expect "a search of the files that fails, no place fails afterwards: named once without a place, the copies are kept, the scrub fails" "1|1|1|$all_kept" \
    "$rc|$(grep -cF "cannot be searched (see find's message)" "$SB/out")|$(grep -cF "cloud-init's files and logs cannot be searched (see find's message); what could not be read there is neither scrubbed nor deleted" "$SB/out")|$(kept_copies)"
# A directory on another file system is not entered (find -xdev). A mount
# needs root, so the other file system is planted in what stat says of the
# directory: the scrub tells the file system by it. What is checked is that
# such a directory is named and keeps the copies; that find does not enter a
# real one is find's own.
# stub_stat PATTERN [FROM]: a stat in $SB/stub that gives a device number of
# its own for a file that matches PATTERN (a case pattern), from the FROM-th
# time it is asked for such a file on (1 when not given: always), and runs the
# real one otherwise. The scrub asks for /var/lib/cloud/data once when it
# looks for directories on another file system, and once more when it hands
# out the status and result of an instance whose secrets are unknown.
stub_stat() {
    mkdir -p "$SB/stub"
    : >"$SB/stub/stat-calls"
    # shellcheck disable=SC2016 # expanded by the stub, not here
    printf '#!/usr/bin/env bash\ncase "${!#}" in %s)\n    echo asked >>%q\n    if [ "$(wc -l <%q)" -ge %q ]; then echo 4242; exit 0; fi ;;\nesac\nexec %q "$@"\n' \
        "$1" "$SB/stub/stat-calls" "$SB/stub/stat-calls" "${2:-1}" "$(command -v stat)" >"$SB/stub/stat"
    chmod +x "$SB/stub/stat"
}
# In place of an instance directory: named and kept always, like a link.
new_appliance
booted iid-1
mounted=$SB/var/lib/cloud/instances/iid-mounted
mkdir -p "$mounted"
stub_stat '*/instances/iid-mounted'
rc=$(PATH=$SB/stub:$PATH run_scrub)
expect "another file system: an instance directory on one is named once, the copies are kept, the scrub fails" "1|1|$all_kept|none" \
    "$rc|$(grep -cF "$mounted is on another file system than $SB/var/lib/cloud/instances; the copies of the provisioning data in it are neither read nor deleted" "$SB/out")|$(kept_copies)|$(found "$SB"/var/log/cloud-init*.log)"
new_appliance
mounted=$SB/var/lib/cloud/instances/iid-mounted
mkdir -p "$mounted"
stub_stat '*/instances/iid-mounted'
expect "another file system: an instance directory on one, nothing learned: the scrub still fails and names it" "1|yes" \
    "$(PATH=$SB/stub:$PATH run_scrub)|$(has "$mounted is on another file system than $SB/var/lib/cloud/instances" "$(out)")"
# Any other directory, such as /var/lib/cloud/data: the files in it are not
# searched, so when there is something to scrub the copies stay.
new_appliance
booted iid-1
stub_stat '*/var/lib/cloud/data'
rc=$(PATH=$SB/stub:$PATH run_scrub)
expect "another file system: /var/lib/cloud/data on one is named, the copies are kept, the scrub fails" "1|yes|$all_kept" \
    "$rc|$(has "$SB/var/lib/cloud/data is on another file system than the directory it is in; the provisioned secrets in it are not scrubbed" "$(out)")|$(kept_copies)"
# The same without provisioning data: nothing to scrub, it is only named.
new_appliance
mkdir -p "$SB/var/lib/cloud/data"
stub_stat '*/var/lib/cloud/data'
expect "another file system: /var/lib/cloud/data on one, no provisioning data: the scrub succeeds and names it once" "0|1" \
    "$(PATH=$SB/stub:$PATH run_scrub)|$(grep -cF "$SB/var/lib/cloud/data is on another file system than the directory it is in; it is not entered" "$SB/out")"
# Everything on one file system, the stub in place: nothing is named.
new_appliance
booted iid-1
stub_stat '*/no-such-directory'
expect "another file system: none, the scrub succeeds and names none" "0|no" \
    "$(PATH=$SB/stub:$PATH run_scrub)|$(has "another file system" "$(out)")"
# unreadable_copies: makes iid-1 an instance none of whose copies can be read,
# with nothing learned from this boot either: its secrets are unknown, so the
# logs go and the status and result are handed out. Sets i to its directory.
unreadable_copies() {
    rm -rf "${SB:?}/run"
    i=$SB/var/lib/cloud/instances/iid-1
    printf 'kamerplanter: [unclosed\n' >"$i/cloud-config.txt"
    printf '#cloud-config\nkamerplanter: [unclosed\n' >"$i/user-data.txt"
    mime_user_data $'#cloud-config\nkamerplanter: [unclosed\n' >"$i/user-data.txt.i"
}
# No copy can be read and /var/lib/cloud/data is on another file system: the
# status and result in it are not rewritten, as nothing else in it is; it is
# named, once, the copies stay, the scrub fails (#155).
new_appliance
booted iid-1
unreadable_copies
status_before=$(md5sum <"$SB/var/lib/cloud/data/status.json")
stub_stat '*/var/lib/cloud/data'
rc=$(PATH=$SB/stub:$PATH run_scrub)
expect "another file system: /var/lib/cloud/data on one, no copy can be read: the status in it is not rewritten, it is named, the copies are kept, the scrub fails" "1|$status_before|no|1|yes|yes|yes" \
    "$rc|$(md5sum <"$SB/var/lib/cloud/data/status.json")|$(has "error messages replaced in" "$(out)")|$(grep -cF "$SB/var/lib/cloud/data is on another file system" "$SB/out")|$(has "$SB/var/lib/cloud/data is on another file system than the directory it is in; the provisioned secrets in it are not scrubbed" "$(out)")|$(exists "$i/cloud-config.txt")|$(exists "$i/user-data.txt")"
# The same when /var/lib/cloud/data shows as another file system only by the
# time the status and result are handed out: it is not among the directories
# named before, so it is named there, once (#173).
new_appliance
booted iid-1
unreadable_copies
status_before=$(md5sum <"$SB/var/lib/cloud/data/status.json")
stub_stat '*/var/lib/cloud/data' 2
rc=$(PATH=$SB/stub:$PATH run_scrub)
expect "another file system: /var/lib/cloud/data on one only when the status is handed out: the status is not rewritten, it is named once, the copies are kept, the scrub fails" "1|$status_before|no|1|1|yes" \
    "$rc|$(md5sum <"$SB/var/lib/cloud/data/status.json")|$(has "error messages replaced in" "$(out)")|$(grep -cF "is on another file system" "$SB/out")|$(grep -cF "$SB/var/lib/cloud/data is on another file system than the directory it is in; the error messages in cloud-init's status and result in it are not replaced" "$SB/out")|$(exists "$i/cloud-config.txt")"
# stub_stat_fails PATTERN [COMMAND [FROM]]: a stat in $SB/stub that fails for
# a file that matches PATTERN (a case pattern), after running COMMAND, from
# the FROM-th time it is asked for such a file on (1 when not given: always),
# and runs the real one otherwise.
stub_stat_fails() {
    mkdir -p "$SB/stub"
    : >"$SB/stub/stat-calls"
    # shellcheck disable=SC2016 # expanded by the stub, not here
    printf '#!/usr/bin/env bash\ncase "${!#}" in %s)\n    echo asked >>%q\n    if [ "$(wc -l <%q)" -ge %q ]; then %s; exit 1; fi ;;\nesac\nexec %q "$@"\n' \
        "$1" "$SB/stub/stat-calls" "$SB/stub/stat-calls" "${3:-1}" "${2:-:}" "$(command -v stat)" >"$SB/stub/stat"
    chmod +x "$SB/stub/stat"
}
# The file system of /var/lib/cloud/data cannot be told: the status is not
# rewritten either. The one cause is named once, as a file system that cannot
# be told, not as a search that failed: find printed nothing (#170).
new_appliance
booted iid-1
unreadable_copies
status_before=$(md5sum <"$SB/var/lib/cloud/data/status.json")
stub_stat_fails '*/var/lib/cloud/data'
rc=$(PATH=$SB/stub:$PATH run_scrub)
expect "another file system: that of /var/lib/cloud/data cannot be told, no copy can be read: the status is not rewritten, that is named once and as no failed search, the copies are kept, the scrub fails" "1|$status_before|1|1|no|yes" \
    "$rc|$(md5sum <"$SB/var/lib/cloud/data/status.json")|$(grep -cF "cannot be told" "$SB/out")|$(grep -cF "the file system of $SB/var/lib/cloud/data cannot be told; whether everything in it was searched is not known" "$SB/out")|$(has "cannot be searched" "$(out)")|$(exists "$i/cloud-config.txt")"
# It cannot be told only by the time the status and result are handed out:
# named there, once.
new_appliance
booted iid-1
unreadable_copies
status_before=$(md5sum <"$SB/var/lib/cloud/data/status.json")
stub_stat_fails '*/var/lib/cloud/data' : 2
rc=$(PATH=$SB/stub:$PATH run_scrub)
expect "another file system: that of /var/lib/cloud/data cannot be told only when the status is handed out: the status is not rewritten, that is named once, the copies are kept, the scrub fails" "1|$status_before|1|1|yes" \
    "$rc|$(md5sum <"$SB/var/lib/cloud/data/status.json")|$(grep -cF "cannot be told" "$SB/out")|$(grep -cF "whether $SB/var/lib/cloud/data is on another file system cannot be told; the error messages in cloud-init's status and result in it are not replaced" "$SB/out")|$(exists "$i/cloud-config.txt")"
# A /var/lib/cloud/data that is gone by the time the status and result are
# handed out holds none: no failure, as for a directory that is gone when the
# directories on another file system are looked for (#170). The stub moves it
# away when asked the second time: for the scrub it is gone, as a deleted one
# is, and what was in it is not looked at here.
new_appliance
booted iid-1
unreadable_copies
# shellcheck disable=SC2016 # expanded by the stub, not here
stub_stat_fails '*/var/lib/cloud/data' 'mv -- "${!#}" "${!#}.moved"' 2
rc=$(PATH=$SB/stub:$PATH run_scrub)
expect "a /var/lib/cloud/data that is gone when the status is handed out: no failure, the scrub succeeds, the copies go" "0|no|no|no|no" \
    "$rc|$(exists "$SB/var/lib/cloud/data")|$(has "cannot be told" "$(out)")|$(has "cannot be searched" "$(out)")|$(exists "$i/cloud-config.txt")"
# The file system of /var/lib/cloud itself cannot be told: no directory below
# it is compared. Named once, by /var/lib/cloud.
new_appliance
booted iid-1
stub_stat_fails '*/var/lib/cloud/'
rc=$(PATH=$SB/stub:$PATH run_scrub)
expect "the file system of /var/lib/cloud cannot be told: the scrub fails, names it once and as no failed search, keeps the copies" "1|1|1|no|$all_kept" \
    "$rc|$(grep -cF "cannot be told" "$SB/out")|$(grep -cF "the file system of $SB/var/lib/cloud cannot be told; whether everything in it was searched is not known" "$SB/out")|$(has "cannot be searched" "$(out)")|$(kept_copies)"
# A directory that is gone between the search and the question for its file
# system is on none: no failure (#155). The stub removes it when asked.
new_appliance
booted iid-1
mkdir -p "$SB/var/lib/cloud/instances/iid-gone"
# shellcheck disable=SC2016 # expanded by the stub, not here
stub_stat_fails '*/instances/iid-gone' 'rmdir -- "${!#}"'
rc=$(PATH=$SB/stub:$PATH run_scrub)
expect "a directory that is gone when its file system is asked for: no failure, the scrub succeeds, the copies go" "0|no|no|no" \
    "$rc|$(exists "$SB/var/lib/cloud/instances/iid-gone")|$(has "cannot be searched" "$(out)")|$(exists "$SB/var/lib/cloud/instances/iid-1/user-data.txt")"
# So is a place the directories on another file system are looked for in, such
# as /var/lib/cloud/instances. The stub moves it away when asked.
new_appliance
booted iid-1
# shellcheck disable=SC2016 # expanded by the stub, not here
stub_stat_fails '*/var/lib/cloud/instances' 'mv -- "${!#}" "${!#}.moved"'
rc=$(PATH=$SB/stub:$PATH run_scrub)
expect "a place that is gone when its file system is asked for: no failure, the scrub succeeds" "0|no|no|no" \
    "$rc|$(exists "$SB/var/lib/cloud/instances")|$(has "cannot be told" "$(out)")|$(has "cannot be searched" "$(out)")"
# One that is still there but whose file system cannot be told is a failure:
# named once, though two searches meet it, as a file system that cannot be
# told and not as a search that failed, which find would have named (#170).
# The copies stay.
new_appliance
booted iid-1
mkdir -p "$SB/var/lib/cloud/instances/iid-untold"
stub_stat_fails '*/instances/iid-untold'
rc=$(PATH=$SB/stub:$PATH run_scrub)
expect "a directory whose file system cannot be told: the scrub fails, names it once and as no failed search, keeps the copies" "1|1|1|no|$all_kept" \
    "$rc|$(grep -cF "cannot be told" "$SB/out")|$(grep -cF "the file system of $SB/var/lib/cloud/instances/iid-untold cannot be told; whether everything in it was searched is not known" "$SB/out")|$(has "cannot be searched" "$(out)")|$(kept_copies)"
# /var/lib/cloud swapped for a symbolic link that leads nowhere, between the
# look at it and the question for its file system: stat fails on it as on a
# place that is gone, but something is there. It is not gone (#184): named,
# the scrub fails, and what was moved away is left as it is.
new_appliance
booted iid-1
# shellcheck disable=SC2016 # expanded by the stub, not here
stub_stat_fails '*/var/lib/cloud/' 'd=${!#}; d=${d%/}; mv -- "$d" "$d.moved" && ln -s "$d.nowhere" "$d"'
rc=$(PATH=$SB/stub:$PATH run_scrub)
expect "/var/lib/cloud swapped for a link that leads nowhere when its file system is asked for: not gone, named once, the scrub fails" "1|1|1|yes" \
    "$rc|$(grep -cF "cannot be told" "$SB/out")|$(grep -cF "the file system of $SB/var/lib/cloud cannot be told; whether everything in it was searched is not known" "$SB/out")|$(exists "$SB/var/lib/cloud.moved/instances/iid-1/user-data.txt")"
# With nothing in its place it is gone: no failure, as for the instances above.
new_appliance
booted iid-1
# shellcheck disable=SC2016 # expanded by the stub, not here
stub_stat_fails '*/var/lib/cloud/' 'd=${!#}; d=${d%/}; mv -- "$d" "$d.moved"'
rc=$(PATH=$SB/stub:$PATH run_scrub)
expect "a /var/lib/cloud that is gone when its file system is asked for: no failure, the scrub succeeds" "0|no|no|no" \
    "$rc|$(exists "$SB/var/lib/cloud")|$(has "cannot be told" "$(out)")|$(has "cannot be searched" "$(out)")"
# So when it is gone only by the time the status and result are handed out
# (asked the second time): it holds none, as a /var/lib/cloud/data that is
# gone by then (#184).
new_appliance
booted iid-1
unreadable_copies
# shellcheck disable=SC2016 # expanded by the stub, not here
stub_stat_fails '*/var/lib/cloud/' 'd=${!#}; d=${d%/}; mv -- "$d" "$d.moved"' 2
rc=$(PATH=$SB/stub:$PATH run_scrub)
expect "a /var/lib/cloud that is gone when the status is handed out: no failure, the scrub succeeds" "0|no|no|no" \
    "$rc|$(exists "$SB/var/lib/cloud")|$(has "cannot be told" "$(out)")|$(has "cannot be searched" "$(out)")"
# Still there by then, its file system cannot be told: the status is not
# rewritten, and that is named once, by /var/lib/cloud (#184).
new_appliance
booted iid-1
unreadable_copies
status_before=$(md5sum <"$SB/var/lib/cloud/data/status.json")
stub_stat_fails '*/var/lib/cloud/' : 2
rc=$(PATH=$SB/stub:$PATH run_scrub)
expect "the file system of /var/lib/cloud cannot be told only when the status is handed out: the status is not rewritten, that is named once, the copies are kept, the scrub fails" "1|$status_before|1|1|yes" \
    "$rc|$(md5sum <"$SB/var/lib/cloud/data/status.json")|$(grep -cF "cannot be told" "$SB/out")|$(grep -cF "the file system of $SB/var/lib/cloud cannot be told, and so not whether $SB/var/lib/cloud/data is on another one; the error messages in cloud-init's status and result in it are not replaced" "$SB/out")|$(exists "$i/cloud-config.txt")"
# Two causes, two messages: the file system of /var/lib/cloud cannot be told
# when the directories on another one are looked for (asked the first time),
# and that of /var/lib/cloud/data cannot when the status and result are handed
# out. The first, named, does not cover the second (#184).
new_appliance
booted iid-1
unreadable_copies
mkdir -p "$SB/stub"
: >"$SB/stub/stat-calls"
# shellcheck disable=SC2016 # expanded by the stub, not here
printf '#!/usr/bin/env bash\ncase "${!#}" in\n    */var/lib/cloud/data) exit 1 ;;\n    */var/lib/cloud/)\n        echo asked >>%q\n        if [ "$(wc -l <%q)" -eq 1 ]; then exit 1; fi ;;\nesac\nexec %q "$@"\n' \
    "$SB/stub/stat-calls" "$SB/stub/stat-calls" "$(command -v stat)" >"$SB/stub/stat"
chmod +x "$SB/stub/stat"
rc=$(PATH=$SB/stub:$PATH run_scrub)
expect "the file system of /var/lib/cloud cannot be told, then that of /var/lib/cloud/data when the status is handed out: each is named once, the copies are kept, the scrub fails" "1|2|1|1|yes" \
    "$rc|$(grep -cF "cannot be told" "$SB/out")|$(grep -cF "the file system of $SB/var/lib/cloud cannot be told; whether everything in it was searched is not known" "$SB/out")|$(grep -cF "whether $SB/var/lib/cloud/data is on another file system cannot be told; the error messages in cloud-init's status and result in it are not replaced" "$SB/out")|$(exists "$i/cloud-config.txt")"

# --- an instance with nothing but an obj.pkl: its secrets are not known (#120) ---
# The pickle is not read, so nothing is learned from the instance: the logs
# go and the error messages are replaced before the pickle is deleted, or the
# values would stay in them with nothing left to learn them from.
new_appliance
booted iid-1
rm -rf "$SB/run"
i=$SB/var/lib/cloud/instances/iid-1
rm -f "$i/cloud-config.txt" "$i/user-data.txt" "$i/user-data.txt.i"
rc=$(run_scrub)
expect "only an obj.pkl: the instance is unknown and named, the logs go, the error messages are replaced, the pickle is deleted" "0|yes|no|no|REDACTED|no" \
    "$rc|$(has "$i: no copy of the cloud-config can be read; the provisioned secrets in it are not known, so cloud-init's logs are deleted" "$(out)")|$(exists "$SB/var/log/cloud-init.log")|$(exists "$SB/var/log/cloud-init-output.log")|$(jq -r '.v1.init.errors[0]' "$SB/var/lib/cloud/data/status.json")|$(exists "$i/obj.pkl")"
expect "only an obj.pkl: no provisioned secret is left under /var/lib/cloud or /var/log" none \
    "$(found "$SB/var/lib/cloud" "$SB/var/log")"
# Next to an instance whose copies can be read: still unknown, the logs go.
new_appliance
booted iid-1
booted iid-2
rm -rf "$SB/run"
i=$SB/var/lib/cloud/instances/iid-1
rm -f "$i/cloud-config.txt" "$i/user-data.txt" "$i/user-data.txt.i"
rc=$(run_scrub)
expect "only an obj.pkl, next to an instance that can be read: it is unknown all the same, the logs go, every copy is deleted" "0|yes|no|no|no|none" \
    "$rc|$(has "$i: no copy of the cloud-config can be read" "$(out)")|$(has "$SB/var/lib/cloud/instances/iid-2: no copy" "$(out)")|$(exists "$SB/var/log/cloud-init.log")|$(exists "$i/obj.pkl")|$(found "$SB/var/lib/cloud" "$SB/var/log")"
# The pickle and a log that cannot be deleted: the pickle is kept, so that the
# next boot finds the instance unknown again and retries (#93).
new_appliance
booted iid-1
rm -rf "$SB/run"
i=$SB/var/lib/cloud/instances/iid-1
rm -f "$i/cloud-config.txt" "$i/user-data.txt" "$i/user-data.txt.i"
if [ -z "$modes_bind" ]; then
    skipped "only an obj.pkl and a log that cannot be deleted"
else
    chmod 0500 "$SB/var/log"
    rc=$(run_scrub)
    chmod 0700 "$SB/var/log"
    expect "only an obj.pkl and a log that cannot be deleted: the pickle is kept, the scrub fails" "1|yes|yes" \
        "$rc|$(exists "$i/obj.pkl")|$(has "$SB/var/log/cloud-init.log cannot be deleted" "$(out)")"
fi

# --- of an instance's copies, those that could be read are deleted last (#155) ---
# stub_rm N: a rm in $SB/stub that notes each file it is asked to delete in
# $SB/removed and deletes the first N only: after them the run is as a boot
# that ended in between.
stub_rm() {
    mkdir -p "$SB/stub"
    : >"$SB/removed"
    # shellcheck disable=SC2016 # expanded by the stub, not here
    printf '#!/usr/bin/env bash\necho "${!#}" >>%q\n[ "$(wc -l <%q)" -le %q ] || exit 1\nexec %q "$@"\n' \
        "$SB/removed" "$SB/removed" "$1" "$(command -v rm)" >"$SB/stub/rm"
    chmod +x "$SB/stub/rm"
}
# A Jinja template as user-data.txt is not read here: cloud-config.txt is the
# only copy to learn from. The run ends after two deletions; what it leaves
# must not be an instance whose secrets are unknown, or the next boot would
# delete the logs.
new_appliance
booted iid-1
rm -rf "$SB/run"
i=$SB/var/lib/cloud/instances/iid-1
{ echo '## template: jinja'; user_data; } >"$i/user-data.txt"
rm -f "$i/user-data.txt.i"
stub_rm 2
rc=$(PATH=$SB/stub:$PATH run_scrub)
expect "a run that ends while the copies are deleted: the pickle went first, cloud-config.txt is asked for last and left" "1|obj.pkl user-data.txt cloud-config.txt|no|no|yes" \
    "$rc|$(sed 's|.*/||' "$SB/removed" | paste -sd ' ')|$(exists "$i/obj.pkl")|$(exists "$i/user-data.txt")|$(exists "$i/cloud-config.txt")"
rc=$(run_scrub)
expect "the boot after it: the instance is not unknown, the logs are kept and scrubbed, the last copy goes" "0|no|yes|none|no" \
    "$rc|$(has "no copy of the cloud-config can be read" "$(out)")|$(exists "$SB/var/log/cloud-init.log")|$(found "$SB"/var/log/cloud-init*.log)|$(exists "$i/cloud-config.txt")"
# The other way round (#46): cloud-config.txt cannot be read, user-data.txt
# can and is the only copy to learn from, so it goes last.
new_appliance
booted iid-1
rm -rf "$SB/run"
i=$SB/var/lib/cloud/instances/iid-1
printf 'kamerplanter: [unclosed\n' >"$i/cloud-config.txt"
rm -f "$i/user-data.txt.i"
stub_rm 2
rc=$(PATH=$SB/stub:$PATH run_scrub)
expect "a run that ends while the copies are deleted, cloud-config.txt unreadable: it goes before user-data.txt, which is left" "1|obj.pkl cloud-config.txt user-data.txt|no|yes" \
    "$rc|$(sed 's|.*/||' "$SB/removed" | paste -sd ' ')|$(exists "$i/cloud-config.txt")|$(exists "$i/user-data.txt")"
rc=$(run_scrub)
expect "the boot after it, cloud-config.txt unreadable: the instance is not unknown, the logs are kept, the last copy goes" "0|no|yes|no" \
    "$rc|$(has "no copy of the cloud-config can be read" "$(out)")|$(exists "$SB/var/log/cloud-init.log")|$(exists "$i/user-data.txt")"
# Two instances with every copy, all of them read: all the pickles before any
# other copy, every cloud-config.txt after the last other copy of an instance.
new_appliance
booted iid-0
booted iid-1
stub_rm 99
rc=$(PATH=$SB/stub:$PATH run_scrub)
expect "the order of deletion over two instances: the pickles first, every cloud-config.txt last" "0|8|yes|yes" \
    "$rc|$(grep -c '/instances/' "$SB/removed")|$(awk '/\/obj\.pkl$/ { if (other) bad = 1; next } /\/instances\// { other = 1 } END { print bad ? "no" : "yes" }' "$SB/removed")|$(awk '/\/cloud-config\.txt$/ { config = 1; next } /\/instances\// && config { bad = 1 } END { print bad ? "no" : "yes" }' "$SB/removed")"

# --- a value too short to be searched for: named by its key only ---
new_appliance
booted iid-1
jq -c '.kamerplanter.secrets.ARANGODB_PASSWORD = "short1"' "$SB/run/cloud-init/combined-cloud-config.json" >"$SB/c" &&
    mv "$SB/c" "$SB/run/cloud-init/combined-cloud-config.json"
echo "a log line with short1 in it" >>"$SB/var/log/cloud-init.log"
expect "a short value: the scrub succeeds, names the key, not the value, and leaves the logs readable" "0|yes|no|yes" \
    "$(run_scrub)|$(has "the provisioned value of ARANGODB_PASSWORD, or a line of it, is shorter than 8 characters" "$(out)")|$(has short1 "$(out)")|$(has "a log line with short1 in it" "$(cat "$SB/var/log/cloud-init.log")")"

# --- a NUL in a key or value: the pairs stay aligned, no value is named as a key ---
new_appliance
booted iid-1
jq -c '.kamerplanter.secrets += {"NUL_IN_VALUE": "nulpartone\u0000nulparttwo", "ODD\u0000KEY": "nulshiftedsecret"}' \
    "$SB/run/cloud-init/combined-cloud-config.json" >"$SB/c" &&
    mv "$SB/c" "$SB/run/cloud-init/combined-cloud-config.json"
echo "a log line with nulparttwo and nulshiftedsecret in it" >>"$SB/var/log/cloud-init.log"
expect "a NUL in a key or value: both parts and the next value are replaced, no value is named in the output" "0|no|no|no|no|no" \
    "$(run_scrub)|$(has nulparttwo "$(cat "$SB/var/log/cloud-init.log")")|$(has nulshiftedsecret "$(cat "$SB/var/log/cloud-init.log")")|$(has nulshiftedsecret "$(out)")|$(has nulpartone "$(out)")|$(has nulparttwo "$(out)")"

# A single NUL in a value, followed by a short value: a NUL left in would
# shift every later pair by one, the short value's key would be searched for
# as a value, and the next setting's value would not be searched for (#82).
new_appliance
booted iid-1
jq -c '.kamerplanter.secrets += {"NUL_ONCE": "nulsoloone\u0000nulsolotwo"} | .kamerplanter.secrets += {"SHORT_AFTER_NUL": "short3"}' \
    "$SB/run/cloud-init/combined-cloud-config.json" >"$SB/c" &&
    mv "$SB/c" "$SB/run/cloud-init/combined-cloud-config.json"
echo "a log line with nulsoloone and nulsolotwo in it" >>"$SB/var/log/cloud-init.log"
log=$SB/var/log/cloud-init.log
expect "a single NUL in a value, then a short value: the pairs stay aligned, the short value's key is named, the next value is replaced" "0|no|no|yes|no|no|no|yes" \
    "$(run_scrub)|$(has nulsoloone "$(cat "$log")")|$(has nulsolotwo "$(cat "$log")")|$(has "the provisioned value of SHORT_AFTER_NUL, or a line of it, is shorter than 8 characters" "$(out)")|$(has short3 "$(out)")|$(has nulsoloone "$(out)")|$(has nulsolotwo "$(out)")|$(has "LOG_PSEUDONYM_SALT=REDACTED" "$(cat "$log")")"

# --- a copy that cannot be deleted: named, the unit fails (#76) ---
# The copies are not rewritten, so one left behind still holds the values.
new_appliance
booted iid-1
if [ -z "$modes_bind" ]; then
    skipped "a copy that cannot be deleted"
else
    chmod 0500 "$SB/var/lib/cloud/instances/iid-1"
    rc=$(run_scrub)
    chmod 0700 "$SB/var/lib/cloud/instances/iid-1"
    expect "a copy that cannot be deleted: the scrub fails, names it, never the value, and the logs are scrubbed" "1|yes|yes|no|none" \
        "$rc|$(has "$SB/var/lib/cloud/instances/iid-1/user-data.txt cannot be deleted; it still holds the provisioned secrets" "$(out)")|$(exists "$SB/var/lib/cloud/instances/iid-1/user-data.txt")|$(has "$jwt" "$(out)")|$(found "$SB"/var/log/cloud-init*.log)"
fi

# --- a file that cannot be rewritten: the unit fails and names it ---
new_appliance
booted iid-1
if [ -z "$modes_bind" ]; then
    skipped "a file that cannot be rewritten"
else
    chmod 0500 "$SB/var/lib/cloud/data"
    rc=$(run_scrub)
    chmod 0700 "$SB/var/lib/cloud/data"
    expect "a file that cannot be rewritten: the scrub fails and names it, never the value" "1|yes|no" \
        "$rc|$(has "$SB/var/lib/cloud/data/status.json still holds provisioned secrets" "$(out)")|$(has "$quoted" "$(out)")"
    expect "a file that cannot be rewritten: the rest is scrubbed, the copies are kept for the next boot to retry" "yes|none|yes" \
        "$(exists "$SB/var/lib/cloud/instances/iid-1/user-data.txt")|$(found "$SB"/var/log/cloud-init*.log)|$(has "copies of the provisioning data are kept until the next boot retries" "$(out)")"
    # A kept copy keeps its values, or the next boot would learn none from it (#76).
    expect "a file that cannot be rewritten: the kept copies still hold the values to learn" "yes|yes" \
        "$(grep -qF -- "$jwt" "$SB/var/lib/cloud/instances/iid-1/user-data.txt" && echo yes)|$(grep -qF -- "$jwt" "$SB/var/lib/cloud/instances/iid-1/cloud-config.txt" && echo yes)"
fi

# --- each value is searched for in the forms Python prints it in (SEC-004) ---
# Each value has an ASCII head and tail that survive every form. form_one
# holds a quote, an apostrophe, a backslash, a non-ASCII and an astral
# character; form_two only an apostrophe, so that repr takes double quotes.
# form_three holds an apostrophe, a control and a non-ASCII character and no
# quote: alone, repr takes double quotes and leaves the apostrophe bare, and
# the control character sets each form apart from every other (repr \x01,
# JSON \u0001), so that every planted line needs the form it shows, and
# every form the scrub's Python makes is planted (#155). One of them, the
# value as it stands inside a JSON text, is made by jq as well: without
# Python's the line would still be redacted.
form_one_head=scrub-form-one-head
form_one_tail=form-one-tail-eeeeeeee
form_two_head=scrub-form-two-head
form_two_tail=form-two-tail-ffffffff
form_one="$form_one_head-\"a'ss\\wörd😀-$form_one_tail"
form_two="$form_two_head-it's-$form_two_tail"
form_three_head=scrub-form-three-head
form_three_tail=form-three-tail-iiiiiiii
form_three="$form_three_head-it's"$'\x01'"wörd-$form_three_tail"
# plant_forms < VALUES (NUL-separated): one log line per form of each value:
# repr alone, in a dict, in a longer string, in one that holds a quote too
# (the apostrophe escaped), ascii and the repr of its UTF-8 bytes, each alone
# and in a string that holds a quote, json.dumps with and without
# ensure_ascii, a JSON text that quotes it by its repr or ascii, and each of
# the six quoted forms as json.dumps prints it, with and without ensure_ascii:
# 24 lines per value.
plant_forms() {
    python3 -I -c '
import json, sys
for v in sys.stdin.buffer.read().decode("utf-8").split("\0"):
    if not v:
        continue
    b = v.encode("utf-8")
    quoted = (repr(v), repr("say \"" + v + "\""), ascii(v), ascii("say \"" + v + "\""),
              repr(b), repr(b"say \"" + b + b"\""))
    lines = [repr({"KEY": v}), repr("text " + v + " text"), json.dumps(v), json.dumps(v, ensure_ascii=False),
             json.dumps({"errors": ["rejected: %r" % v]}), json.dumps("say \"%a\"" % v, ensure_ascii=False)]
    for q in quoted:
        lines += [q, json.dumps(q), json.dumps(q, ensure_ascii=False)]
    for f in lines:
        sys.stdout.buffer.write(("2026-11-16 10:00:03,000 - planted[DEBUG]: " + f + "\n").encode("utf-8"))
'
}
# form_config: the combined cloud-config of booted, with the values added.
form_config() {
    combined_config | jq -c --arg one "$form_one" --arg two "$form_two" --arg three "$form_three" \
        '.kamerplanter.secrets.FORM_ONE_SECRET = $one | .kamerplanter.secrets.FORM_TWO_SECRET = $two | .kamerplanter.secrets.FORM_THREE_SECRET = $three' \
        >"$SB/run/cloud-init/combined-cloud-config.json"
}
# form_left FILE: the lines of FILE that still hold a head or a tail.
form_left() { grep -cF -e "$form_one_head" -e "$form_one_tail" -e "$form_two_head" -e "$form_two_tail" -e "$form_three_head" -e "$form_three_tail" -- "$1"; }
new_appliance
booted iid-1
form_config
log=$SB/var/log/cloud-init.log
printf '%s\0' "$form_one" "$form_two" "$form_three" | plant_forms >>"$log"
planted=$(grep -c 'planted\[DEBUG\]' "$log")
expect "the forms: every planted line holds a head and a tail before the scrub (the test can fail)" "72|72" \
    "$planted|$(grep 'planted\[DEBUG\]' "$log" | grep -F -e "$form_one_head" -e "$form_two_head" -e "$form_three_head" | grep -cF -e "$form_one_tail" -e "$form_two_tail" -e "$form_three_tail")"
# Every line needs a form of its own: of form_three no two forms are alike but
# where Python prints them alike, so a form the scrub stopped making would
# leave its line.
expect "the forms: form_three is planted in 16 forms that differ (the test can fail)" 16 \
    "$(grep 'planted\[DEBUG\]' "$log" | grep -F -e "$form_three_head" | sed -e "s/.*$form_three_head//" -e "s/$form_three_tail.*//" | LC_ALL=C sort -u | wc -l)"
rc=$(run_scrub)
expect "the forms: the scrub succeeds, no head or tail is left in the log, every planted line is redacted" "0|0|$planted" \
    "$rc|$(form_left "$log")|$(grep 'planted\[DEBUG\]' "$log" | grep -c REDACTED)"

# Python cannot make the forms, or makes none: no value is searched for, the
# copies and the logs stay.
for stub in 'exit 1' 'cat >/dev/null; exit 0'; do
    new_appliance
    booted iid-1
    form_config
    mkdir -p "$SB/stub"
    printf '#!/usr/bin/env bash\ncase "$*" in *spellings*) %s ;; esac\nexec %q "$@"\n' "$stub" "$(command -v python3)" >"$SB/stub/python3"
    chmod +x "$SB/stub/python3"
    rc=$(PATH=$SB/stub:$PATH run_scrub)
    expect "the forms cannot be made ($stub): the scrub fails, says so, keeps the copies and the log" "1|yes|$all_kept|yes" \
        "$rc|$(has "the provisioned secrets cannot be made into search patterns (jq or Python failed, or Python made none); none is searched for" "$(out)")|$(kept_copies)|$(exists "$SB/var/log/cloud-init.log")"
done

# --- merge keys in a copy are resolved, as cloud-init resolves them (SEC-009) ---
merge_secret=scrub-merge-secret-marker-gggggggg
merge_setting=scrub-merge-setting-marker-hhhhhhhh
new_appliance
booted iid-1
rm -rf "$SB/run"
i=$SB/var/lib/cloud/instances/iid-1
rm -f "$i/user-data.txt" "$i/user-data.txt.i"
printf '#cloud-config\nshared: &secrets\n  MERGED_SECRET: %s\nsalted: &salt\n  LOG_PSEUDONYM_SALT: %s\nkamerplanter:\n  secrets:\n    <<: *secrets\n  settings:\n    <<: [*salt]\n' \
    "$merge_secret" "$merge_setting" >"$i/cloud-config.txt"
log=$SB/var/log/cloud-init.log
printf '2026-11-16 10:00:04,000 - merged[DEBUG]: secret %s salt %s\n' "$merge_secret" "$merge_setting" >>"$log"
rc=$(run_scrub)
expect "merge keys: a value merged into secrets and one merged into settings are replaced, the copy goes" "0|no|no|yes|no|no" \
    "$rc|$(has "$merge_secret" "$(cat "$log")")|$(has "$merge_setting" "$(cat "$log")")|$(has "merged[DEBUG]: secret REDACTED salt REDACTED" "$(cat "$log")")|$(exists "$i/cloud-config.txt")|$(has "no copy of the cloud-config can be read" "$(out)")"
# A merge of a scalar is no cloud-config cloud-init reads: the copy cannot be
# read, the instance is unknown, the logs go.
new_appliance
booted iid-1
rm -rf "$SB/run"
i=$SB/var/lib/cloud/instances/iid-1
rm -f "$i/user-data.txt" "$i/user-data.txt.i"
printf '#cloud-config\nkamerplanter:\n  secrets:\n    <<: some text\n' >"$i/cloud-config.txt"
expect "an invalid merge key: the copy cannot be read, the instance is unknown, the logs go" "0|yes|no" \
    "$(run_scrub)|$(has "$i: no copy of the cloud-config can be read" "$(out)")|$(exists "$SB/var/log/cloud-init.log")"

# --- the units (L15, L16) ---
units=$image/usr/lib/systemd/system
scrub_unit=$units/kamerplanter-cloud-init-scrub.service
guard_unit=$units/kamerplanter-metadata-guard.service
expect "units: the scrub runs after the provisioning step and after cloud-init's last stage" "yes|yes" \
    "$(grep -Eq '^After=.*\bkamerplanter-provisioning\.service\b' "$scrub_unit" 2>/dev/null && echo yes)|$(grep -Eq '^After=.*\bcloud-final\.service\b' "$scrub_unit" 2>/dev/null && echo yes)"
expect "units: the scrub never pulls cloud-init in, so a boot without a source does not wait (L4)" no \
    "$(grep -Eq '^(Requires|Wants|Requisite|BindsTo)=.*cloud' "$scrub_unit" 2>/dev/null && echo yes || echo no)"
expect "units: the scrub runs with the services on every boot and is enabled in the image" "yes|yes|yes" \
    "$(grep -qx 'WantedBy=kamerplanter.target' "$scrub_unit" 2>/dev/null && echo yes)|$(grep -qx 'ExecStart=/usr/libexec/kamerplanter/scrub-cloud-init' "$scrub_unit" 2>/dev/null && echo yes)|$(grep -q 'kamerplanter-cloud-init-scrub.service' "$root/image/Containerfile" && echo yes)"
expect "units: the scrub is executable in the image" yes \
    "$(grep -q '/usr/libexec/kamerplanter/scrub-cloud-init' "$root/image/Containerfile" && echo yes)"
expect "units: the metadata rules load early, before the network, enabled in the image" "yes|yes|yes|yes" \
    "$(grep -qx 'DefaultDependencies=no' "$guard_unit" 2>/dev/null && echo yes)|$(grep -Eq '^Before=.*\bnetwork-pre\.target\b' "$guard_unit" 2>/dev/null && echo yes)|$(grep -qx 'WantedBy=sysinit.target' "$guard_unit" 2>/dev/null && echo yes)|$(grep -q 'kamerplanter-metadata-guard.service' "$root/image/Containerfile" && echo yes)"
expect "units: the rules are loaded from the image's file, and nothing flushes the whole ruleset" "yes|no" \
    "$(grep -qx 'ExecStart=/usr/sbin/nft -f /usr/share/kamerplanter/nftables/metadata-guard.nft' "$guard_unit" 2>/dev/null && echo yes)|$(grep -v '^#' "$guard_unit" 2>/dev/null | grep -Eqi '^Exec(Stop|Reload)=|flush' && echo yes || echo no)"
check_unit=$units/kamerplanter-metadata-guard-check.service
check_timer=$units/kamerplanter-metadata-guard-check.timer
expect "units: nftables.service, whose reload and stop flush the whole ruleset, is masked in the image" yes \
    "$(grep -Eq '^\s*(&&\s*)?systemctl mask .*\bnftables\.service\b' "$root/image/Containerfile" && echo yes)"
expect "units: the check of the metadata rules runs every minute and is enabled in the image" "yes|yes|yes" \
    "$(grep -qx 'OnUnitActiveSec=1min' "$check_timer" 2>/dev/null && echo yes)|$(grep -qx 'WantedBy=timers.target' "$check_timer" 2>/dev/null && echo yes)|$(grep -q 'kamerplanter-metadata-guard-check.timer' "$root/image/Containerfile" && echo yes)"
check_exec=$(grep '^ExecStart=' "$check_unit" 2>/dev/null)
expect "units: the check loads the image's rules file on every run, also over a table flushed or edited, and warns when it was missing" "yes|no|yes" \
    "$(has 'exec /usr/sbin/nft -f /usr/share/kamerplanter/nftables/metadata-guard.nft' "$check_exec")|$(grep -Eq 'exit|&& *echo' <<<"$check_exec" && echo yes || echo no)|$(grep -Eq 'nft list table inet kamerplanter_metadata [^;]*\|\| *echo' <<<"$check_exec" && echo yes)"
expect "units: the check never restarts or stops the guard unit, which the containers require, and flushes nothing" "no|no" \
    "$(grep -v '^#' "$check_unit" 2>/dev/null | grep -Eq 'systemctl|^Exec(Stop|Reload)=' && echo yes || echo no)|$(grep -v '^#' "$check_unit" 2>/dev/null | grep -qi flush && echo yes || echo no)"
dropin=$image/usr/share/containers/systemd/kamerplanter-.container.d/10-kamerplanter.conf
expect "units: no container starts without the metadata rules (L16)" "yes|yes" \
    "$(grep -qx 'Requires=kamerplanter-metadata-guard.service' "$dropin" && echo yes)|$(grep -qx 'After=kamerplanter-metadata-guard.service' "$dropin" && echo yes)"

# --- the rules, as text (L16); tests/image/metadata-guard.sh tries them ---
ruleset=$image/usr/share/kamerplanter/nftables/metadata-guard.nft
body=$(grep -v '^[[:space:]]*#' "$ruleset" 2>/dev/null)
expect "rules: a table of their own, replaced on reload, no flush of other tables" "yes|yes|no" \
    "$(has $'table inet kamerplanter_metadata\ndelete table inet kamerplanter_metadata' "$body")|$(has 'table inet kamerplanter_metadata {' "$body")|$(has flush "$body")"
expect "rules: local processes other than root are refused the metadata address" yes \
    "$(grep -Eq '^\s*ip daddr 169\.254\.169\.254 meta skuid != 0 .*(drop|reject)' <<<"$body" && echo yes)"
expect "rules: traffic routed through the appliance, the containers', is refused every link-local address for everyone, only replies of a tracked connection pass, to a link-local client" yes \
    "$(sed -n '/chain forward/,/}/p' <<<"$body" | tr '\n' '~' | grep -Eq '~\s*ct direction reply ip daddr 169\.254\.0\.0/16 accept~\s*ip daddr 169\.254\.0\.0/16 .*(drop|reject)' && echo yes)"
expect "rules: the IPv6 metadata address, too, is refused local processes other than root and routed traffic" "yes|yes" \
    "$(sed -n '/chain output/,/}/p' <<<"$body" | grep -Eq '^\s*ip6 daddr fe80::a9fe:a9fe meta skuid != 0 .*(drop|reject)' && echo yes)|$(sed -n '/chain forward/,/}/p' <<<"$body" | grep -Eq '^\s*ip6 daddr fe80::a9fe:a9fe .*(drop|reject)' && echo yes)"
expect "rules: the output chain hooks output, the forward chain hooks forward" "yes|yes" \
    "$(sed -n '/chain output/,/}/p' <<<"$body" | grep -q 'type filter hook output' && echo yes)|$(sed -n '/chain forward/,/}/p' <<<"$body" | grep -q 'type filter hook forward' && echo yes)"

# --- the containers' network (L16) ---
# The output rule lets uid 0 pass. A rootful container in the host's network
# namespace (Network=host, rootful pasta) sends as uid 0 and would reach the
# metadata service; only on a bridge network, kamerplanter.network, are its
# packets routed, and so refused by the forward rule. A macvlan or ipvlan
# network sends past the forward hook as well, and a pod, a kube unit (its
# hostNetwork) or a build (its RUN steps) carries a network of its own, so
# none of these ships. A container unit must be named kamerplanter-*.container,
# or the drop-in that makes it wait for the rules does not apply to it.
# quadlet_view prints each logical line of a unit as "FILE: LINE": a line
# ending in a backslash is joined with the next, quotes are stripped and
# comments dropped, so that `PodmanArgs="--network" host` and an option on a
# continuation line are seen as Podman reads them. Every finding names its
# file; /dev/null keeps grep from reading stdin when no unit is found.
quadlets=$image/usr/share/containers/systemd
mapfile -t quadlet_files < <(find "$quadlets" -type f \( -name '*.container' -o -name '*.pod' -o -name '*.kube' -o -name '*.build' -o -name '*.network' -o -name '*.volume' -o -path '*.d/*.conf' \) 2>/dev/null | sort)
mapfile -t container_files < <(printf '%s\n' "${quadlet_files[@]}" | grep '\.container$')
rel() { sed "s|^$root/||"; }
quadlet_view() {  # quadlet_view FILE...
    local f
    for f in "$@"; do
        awk -v f="$(rel <<<"$f")" '
            { sub(/\r$/, ""); line = cont ? line " " $0 : $0 }
            line ~ /\\$/ { sub(/\\$/, "", line); cont = 1; next }
            { cont = 0; gsub(/["\047]/, "", line); if (line !~ /^[[:space:]]*[#;]/) print f ": " line }
            END { if (cont) { gsub(/["\047]/, "", line); print f ": " line } }' "$f"
    done
}
view=$(quadlet_view "${quadlet_files[@]}")
listed() { rel | paste -sd ';' | grep . || echo none; }  # findings, or "none"
key() { printf '^[^:]*: [[:space:]]*%s[[:space:]]*=' "$1"; }  # key KEY: a regex for KEY= in the view
expect "network: the container units are found (the test can fail)" yes \
    "$([ "${#container_files[@]}" -gt 0 ] && echo yes)"
expect "network: no pod, kube or build unit ships, each would carry a network of its own" none \
    "$(printf '%s\n' "${quadlet_files[@]}" | grep -E '\.(pod|kube|build)$' | listed)"
expect "network: every container unit is named kamerplanter-*.container, so it waits for the rules" none \
    "$(printf '%s\n' "${container_files[@]}" | grep -v '/kamerplanter-[^/]*\.container$' | listed)"
expect "network: every Network= line, in units and drop-ins, names kamerplanter.network" none \
    "$(grep -E "$(key Network)" <<<"$view" | grep -vE '=[[:space:]]*kamerplanter\.network[[:space:]]*$' | listed)"
expect "network: every container unit has exactly one Network= line" none \
    "$(for f in "${container_files[@]}"; do
        n=$(quadlet_view "$f" | grep -cE "$(key Network)")
        [ "$n" = 1 ] || echo "$f: $n Network= lines"
    done | listed)"
expect "network: no PodmanArgs= sets a network of its own, and no unit joins a pod" "none|none" \
    "$(grep -E "$(key PodmanArgs).*--net(work)?([=[:space:]]|$)" <<<"$view" | listed)|$(grep -E "$(key Pod)" <<<"$view" | listed)"
expect "network: every network is a bridge, none macvlan or ipvlan, which bypass the forward rule" "none|none" \
    "$(grep -E '^[^:]*\.network(\.d/[^:]*)?: ' <<<"$view" | grep -E "$(key Driver)" | grep -vE '=[[:space:]]*bridge[[:space:]]*$' | listed)|$(grep -E '^[^:]*\.network(\.d/[^:]*)?: ' <<<"$view" | grep -E "$(key '(PodmanArgs|Options)')" | grep -E '(--driver|-d)[=[:space:]]*(macvlan|ipvlan)' | listed)"

# --- the containers' way into the host's network namespace (L16) ---
# A container on the bridge can still enter the host's network namespace and
# then send as uid 0 past the output rule: privileged, with the host's PID
# namespace, with a capability to join or change namespaces or to become
# root on the host (SYS_ADMIN, with SYS_PTRACE to reach another process's,
# NET_ADMIN to change the host's rules, SYS_MODULE, DAC_READ_SEARCH), or
# through a mount of the host's /proc (/proc/1/ns/net), its /run (/run/netns,
# the Podman socket, which starts a container as it pleases), its /etc (a
# unit of its own), its container storage, /root, the deployments and the
# boot loader (/sysroot, /ostree, /boot), a parent of one of these (/var,
# /var/lib) or of / itself, or a volume that binds one of these (Device= of a
# .volume), a root file system of the host's (Rootfs=), or with its /proc/sys
# writable or its confinement lifted (Unmask=, SeccompProfile=,
# SecurityLabelDisable=, SecurityLabelType=, --security-opt), from where a
# core_pattern runs a program as root on the host, or with a device of the
# host's (AddDevice=, /dev/mem). None of the shipped units needs any of these.
# PodmanArgs= and GlobalArgs= carry none of these options at all, in no
# spelling (-tv/proc is -t -v /proc), so that each takes its Quadlet key,
# which this test reads; a containers.conf module could set them as
# defaults, so no unit loads one, no global option brings defaults of its
# own (--runtime, --conmon, --url, -r, -c, ...), and no unit names CONTAINERS_CONF,
# CONTAINERS_CONF_OVERRIDE or CONTAINER_HOST, in any section (#83). The Volume=, Mount= and Device= sources are
# checked as Podman reads them (%t is /run for a system unit); a named volume
# has no leading slash and passes. A source spelled with // or a . or ..
# segment, a $ that systemd would expand and any specifier but %t (%E is
# /etc, %S /var/lib, %h root's home) are refused outright, because what they
# name is not visible here. Keys and values match in any case.
# tests/image/metadata-guard.sh checks the same on the generator's output,
# the podman command lines themselves.
# escapes: the lines of a view that open such a way, or nothing.
escapes() {  # escapes < VIEW
    local host='(%t(/[^:,]*)?|/|/(var|var/lib)/?|/(proc|run|var/run|etc|var/lib/containers|root|var/roothome|sysroot|ostree|boot)(/[^:,]*)?)'
    grep -iE "$(key '(PodmanArgs|GlobalArgs)')(.*[[:space:]=])?[[:space:]]*(--privileged|--pid|--pod|--cap-add|--volume|--mount|--module|--rootfs|--hooks-dir|--security-opt|--device|--device-cgroup-rule|--runtime|--conmon|--network-config-dir|--cni-config-dir|--default-mounts-file|--root|--runroot|--url|--connection|--remote|--identity|--config)([=[:space:]]|$)
$(key '(PodmanArgs|GlobalArgs)')(.*[[:space:]=])?[[:space:]]*-[[:alpha:]]*v
$(key GlobalArgs)(.*[[:space:]=])?[[:space:]]*-[[:alpha:]]*[rc]
$(key AddCapability)(.*[[:space:],])?[[:space:]]*(CAP_)?(ALL|SYS_ADMIN|NET_ADMIN|SYS_PTRACE|SYS_MODULE|DAC_READ_SEARCH)([[:space:],]|$)
$(key Volume)[[:space:]]*${host}(:|[[:space:]]*$)
$(key Mount)(.*,)?[[:space:]]*(source|src)=${host}(,|[[:space:]]*$)
$(key Device)[[:space:]]*${host}[[:space:]]*$
$(key '(Volume|Mount|Device)').*(podman|docker)\.sock
$(key '(Volume|Mount|Device)').*(//|/\.\.?([/:,]|[[:space:]]*$))
$(key '(PodmanArgs|GlobalArgs|AddCapability|Volume|Mount|Device)').*\\\$
$(key '(Volume|Mount|Device)').*%([^t%]|$)
$(key '(Environment|PassEnvironment)').*CONTAINER(S_CONF|_HOST|_CONNECTION)
$(key '(ContainersConfModule|Rootfs|Unmask|SeccompProfile|SecurityLabelDisable|SecurityLabelType|AddDevice)')"
}
expect "host namespace: no unit is privileged, joins a host namespace, adds such a capability or device, lifts its confinement or mounts the host's /proc, /run, /etc, /var or /" none \
    "$(escapes <<<"$view" | listed)"
# Podman reads defaults for every container from a containers.conf and a
# mounts.conf, and a service drop-in or a unit of the same name in /etc
# replaces what the generator writes; the image ships none of these (#83).
# tests/image/metadata-guard.sh checks the built image, with what the base
# image brings.
expect "host namespace: the image ships no containers.conf or mounts.conf, no service drop-in and no service in /etc, which outranks the generated units" "none|none" \
    "$(find "$image/usr/share/containers" "$image/etc/containers" -maxdepth 1 \( -name 'containers*.conf' -o -name 'containers*.conf.d' -o -name 'containers*.conf.modules' -o -name mounts.conf \) 2>/dev/null | LC_ALL=C sort | listed)|$( { find "$image/usr/lib/systemd/system" "$image/etc/systemd" \( -name '*.service.d' -o -name service.d \) 2>/dev/null; find "$image/etc/systemd" -name '*.service' 2>/dev/null; } | LC_ALL=C sort | listed)"
# The same rule on planted units, one way in each, and one with harmless keys,
# so that the rule can fail and does not refuse everything.
planted=$work/planted-quadlets
mkdir -p "$planted"
plant() { printf '[Container]\nImage=example.org/i:1\nNetwork=kamerplanter.network\n%s\n' "$2" >"$planted/$1.container"; }
plant privileged 'PodmanArgs=--log-level=info --privileged'
plant privileged-alone 'PodmanArgs=--privileged'
plant cluster 'PodmanArgs=-tv/proc:/hp'
# shellcheck disable=SC2016 # a $ that systemd, not this shell, would expand
plant variable 'Volume=${D}:/hp'
plant dots 'Volume=/var/../proc:/x'
plant rootfs 'Rootfs=/'
plant sys-admin 'AddCapability=SYS_ADMIN'
plant etc 'Volume=/etc:/host-etc'
plant mount-first 'Mount=source=/proc,type=bind,destination=/p'
plant pid 'PodmanArgs="--pid" host'
plant global 'GlobalArgs=--module=host.conf'
plant cap 'AddCapability=CHOWN net_admin'
plant cap-all 'AddCapability=ALL'
plant proc 'Volume=/proc:/host/proc:ro'
plant netns 'Mount=type=bind,source=/run/netns,destination=/netns'
plant socket 'Volume=%t/podman/podman.sock:/sock'
plant root 'Volume=/:/host'
plant module 'ContainersConfModule=/etc/containers/host.conf'
plant specifier 'Volume=%E:/host-etc'
plant parent 'Volume=/var/lib:/l'
plant sysroot 'Mount=type=bind,source=/sysroot,destination=/s'
plant unmask 'Unmask=ALL'
plant security-opt 'PodmanArgs=--security-opt unmask=ALL'
plant pod-arg 'PodmanArgs=--pod=p'
plant add-device 'AddDevice=/dev/mem'
plant device-arg 'PodmanArgs=--device=/dev/mem'
plant runtime 'GlobalArgs=--runtime=/usr/local/bin/wrap'
plant remote-short 'GlobalArgs=-r'
plant conf-override $'[Service]\nEnvironment=CONTAINERS_CONF_OVERRIDE=/etc/x.conf'
printf '[Volume]\nDevice=/run/netns\nType=none\nOptions=bind\n' >"$planted/device.volume"
plant harmless $'AddCapability=CHOWN NET_BIND_SERVICE\nVolume=arangodb.volume:/var/lib/arangodb3\nVolume=/var/lib/kamerplanter/x:/x:ro,z\nMount=type=volume,source=valkey_data,destination=/data\nPodmanArgs=--log-level=info'
mapfile -t planted_files < <(find "$planted" -type f | LC_ALL=C sort)
expect "host namespace: the rule finds each planted way in, and passes the harmless unit" \
    "add-device;cap;cap-all;cluster;conf-override;device;device-arg;dots;etc;global;module;mount-first;netns;parent;pid;pod-arg;privileged;privileged-alone;proc;remote-short;root;rootfs;runtime;security-opt;socket;specifier;sys-admin;sysroot;unmask;variable" \
    "$(quadlet_view "${planted_files[@]}" | escapes | sed -E 's|^[^:]*/([^/:]*)\.[a-z]+: .*|\1|' | LC_ALL=C sort -u | paste -sd ';')"

# --- no provisioned value in anything the scrub printed (L12) ---
leaked=none
for m in "${markers[@]}" short1 short3 nulsoloone nulsolotwo "$form_one_head" "$form_one_tail" "$form_two_head" "$form_two_tail" "$form_three_head" "$form_three_tail" "$merge_secret" "$merge_setting"; do
    if grep -qF -- "$m" "$all_output"; then leaked=$m; fi
done
expect "no provisioned value in anything the scrub printed" "none|yes" "$leaked|$([ -s "$all_output" ] && echo yes)"
expect "nothing outside the sandbox was touched: every file the scrub wrote lies below it" none \
    "$(grep -oE '(^| )/[^ ;:,]*' "$all_output" | sed 's/^ //' | grep -v "^$work/appliance\." | head -n1 | grep . || echo none)"

if [ "$failures" -gt 0 ]; then
    echo "$failures check(s) failed"
    exit 1
fi
# A skipped case is a case that did not run. On a notebook, as root, that is
# said and passes; in CI (GitHub sets CI and GITHUB_ACTIONS) it fails the
# file: the job of ci.yml that runs it is not root, so a skip there means the
# cases of a failing search, deletion or rewrite are no longer checked (#173).
if [ "$skips" -gt 0 ] && [ -n "${CI:-}${GITHUB_ACTIONS:-}" ]; then
    echo "$skips case(s) skipped: in CI every case has to run"
    exit 1
fi
if [ "$skips" -gt 0 ]; then echo "all checks passed, $skips case(s) skipped"; else echo "all checks passed"; fi
