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
# values are learned from it, the logs are scrubbed and kept (#46).
new_appliance
booted iid-1
rm -rf "$SB/run"
printf 'kamerplanter: [unclosed\n' >"$SB/var/lib/cloud/instances/iid-1/cloud-config.txt"
cp "$SB/var/log/cloud-init.log" "$SB/var/log/cloud-init.log.1"
echo "untouched" >"$SB/var/log/messages"
rc=$(run_scrub)
expect "an unreadable cloud-config.txt, a readable user-data.txt: the logs are scrubbed and kept, rotated ones too, the copies go" "0|yes|yes|yes|yes|none|no|no" \
    "$rc|$(exists "$SB/var/log/cloud-init.log")|$(exists "$SB/var/log/cloud-init-output.log")|$(exists "$SB/var/log/cloud-init.log.1")|$(exists "$SB/var/log/messages")|$(found "$SB"/var/log/cloud-init*.log*)|$(exists "$SB/var/lib/cloud/instances/iid-1/cloud-config.txt")|$(exists "$SB/var/lib/cloud/instances/iid-1/user-data.txt")"
expect "an unreadable cloud-config.txt, a readable user-data.txt: the instance's secrets count as known" no \
    "$(has "no copy of the cloud-config can be read" "$(out)")"

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
status_before=$(md5sum <"$SB/var/lib/cloud/data/status.json")
expect "a shell script as user-data: not unknown, the logs and the status are kept, the copy goes" "0|yes|yes|$status_before|no|no" \
    "$(run_scrub)|$(exists "$SB/var/log/cloud-init.log")|$(exists "$SB/var/log/cloud-init-output.log")|$(md5sum <"$SB/var/lib/cloud/data/status.json")|$(has "no copy of the cloud-config can be read" "$(out)")|$(exists "$i/user-data.txt")"

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

# --- symbolic links are never followed ---
new_appliance
booted iid-1
echo "outside $jwt" >"$SB/outside/target"
mkdir -p "$SB/outside/dir"
echo "outside $jwt" >"$SB/outside/dir/user-data.txt"
ln -sfn "$SB/outside/target" "$SB/var/lib/cloud/instances/iid-1/vendor-cloud-config.txt"
rm -f "$SB/var/lib/cloud/instances/iid-1/cloud-config.txt"
ln -sfn "$SB/outside/target" "$SB/var/lib/cloud/instances/iid-1/cloud-config.txt"
ln -sfn "$SB/outside/dir" "$SB/var/lib/cloud/instances/linked"
ln -sfn "$SB/outside/target" "$SB/run/cloud-init/instance-data-sensitive.json.link"
rc=$(run_scrub)
expect "links into other places: the files they point to keep their content" "0|outside $jwt|outside $jwt" \
    "$rc|$(cat "$SB/outside/target")|$(cat "$SB/outside/dir/user-data.txt")"
expect "links: a directory linked into instances/ is not entered" yes "$(exists "$SB/outside/dir/user-data.txt")"
new_appliance
booted iid-1
echo "outside $jwt" >"$SB/outside/log"
rm -f "$SB/var/log/cloud-init.log"
ln -sfn "$SB/outside/log" "$SB/var/log/cloud-init.log"
expect "links: a log that is a link is not rewritten through it" "0|outside $jwt" "$(run_scrub)|$(cat "$SB/outside/log")"
new_appliance
mkdir -p "$SB/outside/cloud/instances/iid-1"
echo "outside $jwt" >"$SB/outside/cloud/instances/iid-1/user-data.txt"
rm -rf "$SB/var/lib/cloud"
ln -sfn "$SB/outside/cloud" "$SB/var/lib/cloud"
mkdir -p "$SB/run/cloud-init"
combined_config >"$SB/run/cloud-init/combined-cloud-config.json"
expect "links: /var/lib/cloud as a link is not scrubbed, and says so" "0|yes|yes" \
    "$(run_scrub)|$(exists "$SB/outside/cloud/instances/iid-1/user-data.txt")|$(has "$SB/var/lib/cloud is a symbolic link; it is not scrubbed" "$(out)")"

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

# --- a file that cannot be rewritten: the unit fails and names it ---
new_appliance
booted iid-1
chmod 0500 "$SB/var/lib/cloud/data"
rc=$(run_scrub)
chmod 0700 "$SB/var/lib/cloud/data"
expect "a file that cannot be rewritten: the scrub fails and names it, never the value" "1|yes|no" \
    "$rc|$(has "$SB/var/lib/cloud/data/status.json still holds provisioned secrets" "$(out)")|$(has "$quoted" "$(out)")"
expect "a file that cannot be rewritten: the rest is scrubbed, the copies are kept for the next boot to retry" "yes|none|yes" \
    "$(exists "$SB/var/lib/cloud/instances/iid-1/user-data.txt")|$(found "$SB"/var/log/cloud-init*.log)|$(has "copies of the provisioning data are kept until the next boot retries" "$(out)")"

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
# core_pattern runs a program as root on the host. None of the shipped units
# needs any of these.
# PodmanArgs= and GlobalArgs= carry none of these options at all, in no
# spelling (-tv/proc is -t -v /proc), so that each takes its Quadlet key,
# which this test reads; a containers.conf module could set them as
# defaults, so no unit loads one. The Volume=, Mount= and Device= sources are
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
    grep -iE "$(key '(PodmanArgs|GlobalArgs)')(.*[[:space:]=])?[[:space:]]*(--privileged|--pid|--pod|--cap-add|--volume|--mount|--module|--rootfs|--hooks-dir|--security-opt)([=[:space:]]|$)
$(key '(PodmanArgs|GlobalArgs)')(.*[[:space:]=])?[[:space:]]*-[[:alpha:]]*v
$(key AddCapability)(.*[[:space:],])?[[:space:]]*(CAP_)?(ALL|SYS_ADMIN|NET_ADMIN|SYS_PTRACE|SYS_MODULE|DAC_READ_SEARCH)([[:space:],]|$)
$(key Volume)[[:space:]]*${host}(:|[[:space:]]*$)
$(key Mount)(.*,)?[[:space:]]*(source|src)=${host}(,|[[:space:]]*$)
$(key Device)[[:space:]]*${host}[[:space:]]*$
$(key '(Volume|Mount|Device)').*(podman|docker)\.sock
$(key '(Volume|Mount|Device)').*(//|/\.\.?([/:,]|[[:space:]]*$))
$(key '(PodmanArgs|GlobalArgs|AddCapability|Volume|Mount|Device)').*\\\$
$(key '(Volume|Mount|Device)').*%([^t%]|$)
$(key '(ContainersConfModule|Rootfs|Unmask|SeccompProfile|SecurityLabelDisable|SecurityLabelType)')"
}
expect "host namespace: no unit is privileged, joins a host namespace, adds such a capability, lifts its confinement or mounts the host's /proc, /run, /etc, /var or /" none \
    "$(escapes <<<"$view" | listed)"
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
printf '[Volume]\nDevice=/run/netns\nType=none\nOptions=bind\n' >"$planted/device.volume"
plant harmless $'AddCapability=CHOWN NET_BIND_SERVICE\nVolume=arangodb.volume:/var/lib/arangodb3\nVolume=/var/lib/kamerplanter/x:/x:ro,z\nMount=type=volume,source=valkey_data,destination=/data\nPodmanArgs=--log-level=info'
mapfile -t planted_files < <(find "$planted" -type f | LC_ALL=C sort)
expect "host namespace: the rule finds each planted way in, and passes the harmless unit" \
    "cap;cap-all;cluster;device;dots;etc;global;module;mount-first;netns;parent;pid;pod-arg;privileged;privileged-alone;proc;root;rootfs;security-opt;socket;specifier;sys-admin;sysroot;unmask;variable" \
    "$(quadlet_view "${planted_files[@]}" | escapes | sed -E 's|^[^:]*/([^/:]*)\.[a-z]+: .*|\1|' | LC_ALL=C sort -u | paste -sd ';')"

# --- no provisioned value in anything the scrub printed (L12) ---
leaked=none
for m in "${markers[@]}" short1; do
    if grep -qF -- "$m" "$all_output"; then leaked=$m; fi
done
expect "no provisioned value in anything the scrub printed" "none|yes" "$leaked|$([ -s "$all_output" ] && echo yes)"
expect "nothing outside the sandbox was touched: every file the scrub wrote lies below it" none \
    "$(grep -oE '(^| )/[^ ;:,]*' "$all_output" | sed 's/^ //' | grep -v "^$work/appliance\." | head -n1 | grep . || echo none)"

if [ "$failures" -gt 0 ]; then
    echo "$failures check(s) failed"
    exit 1
fi
echo "all checks passed"
