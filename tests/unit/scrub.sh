#!/usr/bin/env bash
# Checks the hardening of the provisioning data (spec/distribution-requirements/
# L15, L16): the scrub of cloud-init's copies
# (image/rootfs/usr/libexec/kamerplanter/scrub-cloud-init) on a fake cloud-init
# tree as cloud-init 26.2 leaves it, the units that run the scrub and load the
# metadata rules, and the rules themselves as text. The script runs as it
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
# booted IID: what cloud-init 26.2 leaves after a boot of instance IID with
# that user-data, as the P1 spike found it, plus its record of the instance.
booted() {
    local lib=$SB/var/lib/cloud i=$SB/var/lib/cloud/instances/$1
    mkdir -p "$i/sem" "$i/scripts" "$i/handlers" "$lib/data" "$SB/run/cloud-init"
    user_data >"$i/user-data.txt"
    { echo 'Content-Type: multipart/mixed'; echo; user_data; } >"$i/user-data.txt.i"
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

# A copy of the cloud-config that cannot be read: its values are unknown, so
# cloud-init's logs go, rotated ones included; other logs stay.
new_appliance
booted iid-1
rm -rf "$SB/run"
printf 'kamerplanter: [unclosed\n' >"$SB/var/lib/cloud/instances/iid-1/cloud-config.txt"
cp "$SB/var/log/cloud-init.log" "$SB/var/log/cloud-init.log.1"
echo "untouched" >"$SB/var/log/messages"
rc=$(run_scrub)
expect "an unreadable copy: cloud-init's logs are deleted, rotated ones too, other logs stay, the copies go" "0|no|no|no|yes|no" \
    "$rc|$(exists "$SB/var/log/cloud-init.log")|$(exists "$SB/var/log/cloud-init-output.log")|$(exists "$SB/var/log/cloud-init.log.1")|$(exists "$SB/var/log/messages")|$(exists "$SB/var/lib/cloud/instances/iid-1/cloud-config.txt")"
expect "an unreadable copy: the scrub names it and says why the logs go" yes \
    "$(has "$SB/var/lib/cloud/instances/iid-1/cloud-config.txt cannot be read; the provisioned secrets in it are not known, so cloud-init's logs are deleted" "$(out)")"

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
expect "rules: traffic routed through the appliance, the containers', is refused it for everyone" yes \
    "$(sed -n '/chain forward/,/}/p' <<<"$body" | grep -Eq '^\s*ip daddr 169\.254\.169\.254 .*(drop|reject)' && echo yes)"
expect "rules: the output chain hooks output, the forward chain hooks forward" "yes|yes" \
    "$(sed -n '/chain output/,/}/p' <<<"$body" | grep -q 'type filter hook output' && echo yes)|$(sed -n '/chain forward/,/}/p' <<<"$body" | grep -q 'type filter hook forward' && echo yes)"

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
