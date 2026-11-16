#!/usr/bin/env bash
# Checks the provisioned secrets (spec/distribution-requirements/ D9, D10,
# L12-L14, L17, Q5): the provisioning step
# (image/rootfs/usr/libexec/kamerplanter/provisioning) staging
# kamerplanter: -> secrets: of fake cloud-init output in memory, and the
# configuration check (configure) taking it, and the system credentials
# kamerplanter.secret.<KEY>, into the secrets file: once per instance for the
# map, on any boot for a credential, only into missing keys, after the data
# disk is in place, never printing a value. The scripts run as they ship, in
# a sandbox (lib/sandbox.sh); every command that would reach the system is a
# stub. Needs no root, no cloud-init and no VM.
#
# Usage: tests/unit/secrets.sh
set -uo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
image=$root/image/rootfs
# shellcheck source=image/rootfs/usr/lib/kamerplanter/env.sh
. "$image/usr/lib/kamerplanter/env.sh"
# shellcheck source=tests/unit/lib/sandbox.sh
. "$root/tests/unit/lib/sandbox.sh"
set +e

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# Everything the step and the check print, over all cases: no value of a
# provisioned secret may ever be in it.
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

# Values of provisioned secrets, each recognisable in any output.
fernet_of() { printf '%s' "$1" | sha256sum | head -c 43 | tr '0-9a-f' 'A-Za-p'; printf '='; }
map_jwt=map-jwt-marker-$(printf 'a%.0s' {1..40})
map_fernet=$(fernet_of map)
map_salt=map-salt-marker-$(printf 'b%.0s' {1..40})
cred_jwt=cred-jwt-marker-$(printf 'c%.0s' {1..40})
cred_salt=cred-salt-marker-$(printf 'd%.0s' {1..40})
held_jwt=held-jwt-marker-$(printf 'e%.0s' {1..40})
markers=("$map_jwt" "$map_fernet" "$map_salt" "$cred_jwt" "$cred_salt" "$held_jwt")

# --- the sandbox: one appliance, booted again and again ---
# new_appliance: a fresh sandbox in SB with the step, the check and the
# image's defaults; a data disk is not set up.
new_appliance() {
    SB=$(mktemp -d "$work/appliance.XXXXXX")
    sandbox_install "$SB" "$image" /usr/libexec/kamerplanter/provisioning /usr/libexec/kamerplanter/configure \
        /usr/lib/kamerplanter/env.sh
    mkdir -p "$SB/usr/share/kamerplanter" "$SB/etc/kamerplanter" "$SB/var/lib/kamerplanter/disks" \
        "$SB/var/lib/kamerplanter/pinned" "$SB/var/lib/kamerplanter/provisioning" "$SB/var/mnt/kamerplanter-data" \
        "$SB/var/lib/containers/storage/volumes/arangodb_data" "$SB/var/lib/containers/storage/volumes/valkey_data" \
        "$SB/run/cloud-init" "$SB/usr/lib/systemd/system-generators" "$SB/creds"
    chmod 0700 "$SB/var/lib/kamerplanter/provisioning"
    cp "$image/usr/share/kamerplanter/kamerplanter.env" "$SB/usr/share/kamerplanter/"
    # The window generator is a stub that always agrees with the boot's.
    printf '#!/usr/bin/bash\nexit 1\n' >"$SB/usr/lib/systemd/system-generators/kamerplanter-update-window"
    chmod 0755 "$SB/usr/lib/systemd/system-generators/kamerplanter-update-window"
}
# reboot: /run is emptied, as at every boot.
reboot() { rm -rf "$SB/run"; mkdir -p "$SB/run/cloud-init"; }
cloud_init() {  # cloud_init PLATFORM INSTANCE_ID CLOUD_CONFIG_JSON: what cloud-init leaves in /run
    printf '{"v1": {"platform": "%s", "instance_id": "%s"}}\n' "$1" "$2" >"$SB/run/cloud-init/instance-data.json"
    printf '%s\n' "$3" >"$SB/run/cloud-init/combined-cloud-config.json"
}
credential() {  # credential KEY VALUE: the system credential kamerplanter.secret.KEY, as systemd passes it
    printf '%s' "$2" >"$SB/creds/kamerplanter.secret.$1"
}
# The commands that reach the system, all stubbed: owner root is what the
# scripts enforce, as any user it is noted only; systemctl and timeout (the
# step reloads through it) only note their calls.
chown() { echo "chown $*" >>"$SB/chown-calls"; }
systemctl() { echo "systemctl $*" >>"$SB/systemctl-calls"; }
timeout() { echo "timeout $*" >>"$SB/systemctl-calls"; }
run_step() {  # prints the exit status; the output is in $SB/out
    (
        export SB
        export -f chown systemctl timeout
        bash "$SB/usr/libexec/kamerplanter/provisioning" >"$SB/out" 2>&1
        echo "$?"
    )
    cat "$SB/out" >>"$all_output"
}
run_configure() {  # [MOUNTED=1] run_configure: prints the exit status; the output is in $SB/out
    (
        MOUNTED=${MOUNTED-}
        sandbox_mounts
        export SB CREDENTIALS_DIRECTORY=$SB/creds
        export -f chown systemctl timeout
        bash "$SB/usr/libexec/kamerplanter/configure" >"$SB/out" 2>&1
        echo "$?"
    )
    cat "$SB/out" >>"$all_output"
}
secret() { sed -n "s/^$1=//p" "$SB/etc/kamerplanter/secrets.env" 2>/dev/null; }  # secret KEY: KEY in the secrets file
lines_of() { grep -c "^$1=" "$SB/etc/kamerplanter/secrets.env" 2>/dev/null; }
app() { sed -n "s/^$1=//p" "$SB/run/kamerplanter/app.env" 2>/dev/null; }
staging=run/kamerplanter-provisioning
staged() { [ -e "$SB/$staging/secrets.env" ] && echo yes || echo no; }
record() { cat "$SB/var/lib/kamerplanter/provisioning/secrets-taken" 2>/dev/null; }
mode() { stat -c %a "$1" 2>/dev/null; }
out() { cat "$SB/out"; }
generated_ok() {  # whether the secrets file holds the five generated secrets in their form
    [[ $(secret ARANGODB_PASSWORD) =~ ^[0-9a-f]{48}$ ]] && [[ $(secret JWT_SECRET_KEY) =~ ^[0-9a-f]{64}$ ]] &&
        [[ $(secret FERNET_KEY) =~ ^[A-Za-z0-9_-]{43}=$ ]] && [[ $(secret ERASURE_TOMBSTONE_SALT) =~ ^[0-9a-f]{64}$ ]] &&
        [[ $(secret LOG_PSEUDONYM_SALT) =~ ^[0-9a-f]{64}$ ]] && echo yes || echo no
}

# --- the place of the staged secrets (L17) ---
expect "staging: in /run, outside /run/kamerplanter, which the check empties when it fails" "yes|no" \
    "$(case ${provisioning_staging-} in /run/?*) echo yes ;; *) echo no ;; esac)|$(case ${provisioning_staging-}/ in /run/kamerplanter/*) echo yes ;; *) echo no ;; esac)"
expect "staging: the record of the instance lies on the system disk beside the provisioning layer" "$provisioning_dir/secrets-taken" "${secrets_taken-}"
expect "only the secrets the check knows are taken over" \
    "ARANGODB_PASSWORD JWT_SECRET_KEY FERNET_KEY ERASURE_TOMBSTONE_SALT LOG_PSEUDONYM_SALT TENANT_EXPORT_SIGNING_SECRET" \
    "${provisionable_secret_keys[*]-}"

# --- without provisioned secrets the secrets file is generated as before (D9, L14) ---
new_appliance
rc=$(run_step)
expect "no provisioning data: the five secrets are generated, nothing is staged or recorded" "0|0|yes|no|" \
    "$rc|$(run_configure)|$(generated_ok)|$(staged)|$(record)"
expect "no provisioning data: and nothing is said to be taken over" no "$(has 'taken over' "$(out)")"

new_appliance
cloud_init nocloud iid-a '{"kamerplanter": {"settings": {"FRONTEND_URL": "https://kp.example.org"}}}'
rc=$(run_step)
expect "data without secrets: an empty map is staged, root only" "0|yes|700|600|yes" \
    "$rc|$(staged)|$(mode "$SB/$staging")|$(mode "$SB/$staging/secrets.env")|$(grep -qx "chown root:root $SB/$staging" "$SB/chown-calls" && echo yes)"
expect "data without secrets: the five secrets are generated, the instance recorded, the staging deleted" '0|yes|"iid-a"|no|no' \
    "$(run_configure)|$(generated_ok)|$(record)|$(staged)|$([ -e "$SB/$staging" ] && echo yes || echo no)"

# --- the map is taken over at the first boot (L12) ---
new_appliance
cloud_init nocloud iid-1 "{\"kamerplanter\": {\"settings\": {\"FRONTEND_URL\": \"https://kp.example.org\"}, \"secrets\": {\"JWT_SECRET_KEY\": \"$map_jwt\", \"FERNET_KEY\": \"$map_fernet\"}}}"
rc=$(run_step)
expect "first boot: the step stages the map in memory, not in the provisioning layer" "0|yes|no|yes" \
    "$rc|$(staged)|$(has "$map_jwt" "$(cat "$SB/var/lib/kamerplanter/provisioning/"* 2>/dev/null)")|$(has '2 entries of kamerplanter: -> secrets: staged' "$(out)")"
rc=$(run_configure)
expect "first boot: the map fills the missing keys, the rest is generated" "0|$map_jwt|$map_fernet|yes" \
    "$rc|$(secret JWT_SECRET_KEY)|$(secret FERNET_KEY)|$([[ $(secret ERASURE_TOMBSTONE_SALT) =~ ^[0-9a-f]{64}$ ]] && echo yes)"
expect "first boot: the services get the provisioned values" "$map_jwt|$map_fernet" "$(app JWT_SECRET_KEY)|$(app FERNET_KEY)"
expect "first boot: each key once in the secrets file, the file 0600" "1|1|600" \
    "$(lines_of JWT_SECRET_KEY)|$(lines_of FERNET_KEY)|$(mode "$SB/etc/kamerplanter/secrets.env")"
expect "first boot: the take-over names the keys and their source, the instance is recorded, the staging deleted" '"iid-1"|no|no|yes' \
    "$(record)|$(staged)|$([ -e "$SB/$staging" ] && echo yes || echo no)|$(has 'taken over into '"$SB"'/etc/kamerplanter/secrets.env: FERNET_KEY (kamerplanter: -> secrets: of the provisioning data); JWT_SECRET_KEY (kamerplanter: -> secrets: of the provisioning data)' "$(out)")"

# A later boot of the same instance, the source still attached: not again.
reboot
cloud_init nocloud iid-1 "{\"kamerplanter\": {\"secrets\": {\"JWT_SECRET_KEY\": \"$map_jwt\", \"LOG_PSEUDONYM_SALT\": \"$map_salt\"}}}"
rc=$(run_step)
expect "later boot, same instance: the map is not staged again" "0|no|yes" \
    "$rc|$(staged)|$(has 'taken over on an earlier boot' "$(out)")"
sed -i '/^JWT_SECRET_KEY=/d; /^LOG_PSEUDONYM_SALT=/d' "$SB/etc/kamerplanter/secrets.env"
rc=$(run_configure)
expect "later boot, same instance: keys deleted since are generated, not taken from the map again" "0|yes|yes|no|no" \
    "$rc|$([[ $(secret JWT_SECRET_KEY) =~ ^[0-9a-f]{64}$ ]] && echo yes)|$([[ $(secret LOG_PSEUDONYM_SALT) =~ ^[0-9a-f]{64}$ ]] && echo yes)|$(has "$map_jwt" "$(cat "$SB/etc/kamerplanter/secrets.env")")|$(has "$map_salt" "$(cat "$SB/etc/kamerplanter/secrets.env")")"
# A new instance (re-provisioned): its map is taken over, into missing keys only.
reboot
cloud_init nocloud iid-2 "{\"kamerplanter\": {\"secrets\": {\"LOG_PSEUDONYM_SALT\": \"$map_salt\"}}}"
run_step >/dev/null
sed -i '/^LOG_PSEUDONYM_SALT=/d' "$SB/etc/kamerplanter/secrets.env"
expect "a new instance: its map is staged and taken over" "0|$map_salt|\"iid-2\"" \
    "$(run_configure)|$(secret LOG_PSEUDONYM_SALT)|$(record)"
# A boot without data never touches the record or the secrets file.
reboot
before=$(cat "$SB/etc/kamerplanter/secrets.env")
expect "a boot without data: nothing staged, the secrets file and the record as they were" "0|0|no|$before|\"iid-2\"" \
    "$(run_step)|$(run_configure)|$(staged)|$(cat "$SB/etc/kamerplanter/secrets.env")|$(record)"
cloud_init none iid-2 "{\"kamerplanter\": {\"secrets\": {\"JWT_SECRET_KEY\": \"$map_jwt\"}}}"
expect "the datasource None: nothing staged" "0|no" "$(run_step)|$(staged)"

# --- a boot on which the secrets file cannot be written retakes (L12, L17, E12) ---
new_appliance
echo 'UUID=0000' >"$SB/var/lib/kamerplanter/disks/data.env"
cloud_init nocloud iid-d "{\"kamerplanter\": {\"secrets\": {\"JWT_SECRET_KEY\": \"$map_jwt\"}}}"
run_step >/dev/null
rc=$(run_configure)
expect "data disk set up but not in place: nothing is written underneath it, the map stays staged, nothing recorded" "1|no|no|yes|" \
    "$rc|$([ -e "$SB/etc/kamerplanter/secrets.env" ] && echo yes || echo no)|$(grep -rlF "$map_jwt" "$SB/etc" "$SB/var" 2>/dev/null | head -n1 | grep -q . && echo yes || echo no)|$(staged)|$(record)"
# The disk is attached, the target restarted: the staged map is taken over.
printf 'JWT_SECRET_KEY=%s\n' "$held_jwt" >"$SB/etc/kamerplanter/secrets.env"
rc=$(MOUNTED=1 run_configure)
expect "the disk in place: an adopted secrets file keeps its value, the rest is generated, the map recorded" "0|$held_jwt|yes|\"iid-d\"|no" \
    "$rc|$(secret JWT_SECRET_KEY)|$([[ $(secret FERNET_KEY) =~ ^[A-Za-z0-9_-]{43}=$ ]] && echo yes)|$(record)|$(staged)"
expect "the disk in place: the kept value is warned about by its key only (Q5)" "yes|no|no" \
    "$(has "warning: JWT_SECRET_KEY from kamerplanter: -> secrets: of the provisioning data differs from the value in $SB/etc/kamerplanter/secrets.env; that value is kept" "$(out)")|$(has "$map_jwt" "$(out)")|$(has "$held_jwt" "$(out)")"
# Or the disk is still missing at this boot, and in place at the next.
new_appliance
echo 'UUID=0000' >"$SB/var/lib/kamerplanter/disks/data.env"
cloud_init nocloud iid-d "{\"kamerplanter\": {\"secrets\": {\"JWT_SECRET_KEY\": \"$map_jwt\"}}}"
run_step >/dev/null
run_configure >/dev/null
reboot
cloud_init nocloud iid-d "{\"kamerplanter\": {\"secrets\": {\"JWT_SECRET_KEY\": \"$map_jwt\"}}}"
expect "the next boot with the disk in place: the map is staged again and taken over" "0|yes|0|$map_jwt|\"iid-d\"" \
    "$(run_step)|$(staged)|$(MOUNTED=1 run_configure)|$(secret JWT_SECRET_KEY)|$(record)"

# --- system credentials fill a missing key on any boot (L13) ---
new_appliance
credential JWT_SECRET_KEY "$cred_jwt"
expect "credential: fills the missing key, without provisioning data" "0|$cred_jwt|yes" \
    "$(run_configure)|$(secret JWT_SECRET_KEY)|$(has 'JWT_SECRET_KEY (the system credential kamerplanter.secret.JWT_SECRET_KEY)' "$(out)")"
sed -i '/^JWT_SECRET_KEY=/d' "$SB/etc/kamerplanter/secrets.env"
reboot
expect "credential: and again on a later boot" "0|$cred_jwt|1" "$(run_configure)|$(secret JWT_SECRET_KEY)|$(lines_of JWT_SECRET_KEY)"
expect "credential: a key the secrets file holds with the same value: nothing said, nothing written" "0|1|no" \
    "$(run_configure)|$(lines_of JWT_SECRET_KEY)|$(has JWT_SECRET_KEY "$(out)")"
sed -i "s/^JWT_SECRET_KEY=.*/JWT_SECRET_KEY=$held_jwt/" "$SB/etc/kamerplanter/secrets.env"
rc=$(run_configure)
expect "credential: a held value is kept, warned about by its key, the services start (Q5)" "0|$held_jwt|yes|no|no" \
    "$rc|$(secret JWT_SECRET_KEY)|$(has 'warning: JWT_SECRET_KEY from the system credential kamerplanter.secret.JWT_SECRET_KEY differs' "$(out)")|$(has "$cred_jwt" "$(out)")|$(has "$held_jwt" "$(out)")"
new_appliance
printf '%s\n' "$cred_salt" >"$SB/creds/kamerplanter.secret.ERASURE_TOMBSTONE_SALT"
expect "credential: a trailing line break is not part of the value" "0|$cred_salt" "$(run_configure)|$(secret ERASURE_TOMBSTONE_SALT)"

# --- a credential wins over the map for the same missing key (L13) ---
new_appliance
cloud_init nocloud iid-c "{\"kamerplanter\": {\"secrets\": {\"JWT_SECRET_KEY\": \"$map_jwt\", \"LOG_PSEUDONYM_SALT\": \"$map_salt\"}}}"
credential JWT_SECRET_KEY "$cred_jwt"
run_step >/dev/null
expect "credential and map: the credential wins, the map fills its other keys" "0|$cred_jwt|$map_salt|1" \
    "$(run_configure)|$(secret JWT_SECRET_KEY)|$(secret LOG_PSEUDONYM_SALT)|$(lines_of JWT_SECRET_KEY)"

# --- invalid keys and values are rejected, nothing provisioned is written ---
# reject NAME CLOUD_CONFIG_JSON MESSAGE: the map keeps the services stopped
# with MESSAGE, writes nothing into the secrets file, generates nothing, and
# stays staged; the instance is not recorded.
reject() {
    new_appliance
    cloud_init nocloud iid-x "$2"
    run_step >/dev/null
    local rc
    rc=$(run_configure)
    expect "invalid map: $1" "1|yes|0|yes|no||yes" \
        "$rc|$(has "$3" "$(out)")|$(wc -c <"$SB/etc/kamerplanter/secrets.env")|$(staged)|$([ -e "$SB/run/kamerplanter/app.env" ] && echo yes || echo no)|$(record)|$(has 'Fix the provisioned secret, in the provisioning data (kamerplanter: -> secrets: is read again at the next boot until it is taken over) or as the system credential kamerplanter.secret.<KEY>, and reboot' "$(out)")"
}
reject "a key that is not a secret, such as a disk's naming (L19)" \
    "{\"kamerplanter\": {\"secrets\": {\"DATA_DISK\": \"/dev/disk/by-id/virtio-x\", \"JWT_SECRET_KEY\": \"$map_jwt\"}}}" \
    'DATA_DISK in kamerplanter: -> secrets: of the provisioning data is no secret the appliance takes over'
reject "a key that is no KEY name is not shown" \
    "{\"kamerplanter\": {\"secrets\": {\"bad key=$map_salt\": \"x\"}}}" \
    'invalid entry of kamerplanter: -> secrets:, a key that is no KEY name'
reject "a key ending in a line break is not shown and splits no line" \
    "{\"kamerplanter\": {\"secrets\": {\"JWT_SECRET_KEY\\n\": \"$map_jwt\"}}}" \
    'invalid entry of kamerplanter: -> secrets:, a key that is no KEY name'
reject "a value with a line break cannot inject a line" \
    "{\"kamerplanter\": {\"secrets\": {\"JWT_SECRET_KEY\": \"$map_jwt\\nDATA_DISK=/dev/sdb\"}}}" \
    'the value of JWT_SECRET_KEY holds a line break or another control character'
reject "a number is no text" \
    '{"kamerplanter": {"secrets": {"ARANGODB_PASSWORD": 123456789012345678901234567890}}}' \
    'the value of ARANGODB_PASSWORD is a number, not a text; quote it'
reject "an empty value" '{"kamerplanter": {"secrets": {"JWT_SECRET_KEY": ""}}}' 'JWT_SECRET_KEY is empty (supplied by kamerplanter: -> secrets:'
reject "a null value" '{"kamerplanter": {"secrets": {"JWT_SECRET_KEY": null}}}' 'the value of JWT_SECRET_KEY is empty, not a text'
reject "a value that fails the check of its key" \
    '{"kamerplanter": {"secrets": {"FERNET_KEY": "not-a-fernet-key"}}}' \
    'FERNET_KEY is not a Fernet key (32 bytes, URL-safe base64, 44 characters) (supplied by kamerplanter: -> secrets: of the provisioning data)'
reject "a value that is not printable ASCII" \
    '{"kamerplanter": {"secrets": {"JWT_SECRET_KEY": "geheim-grün-0123456789012345678901234567890123456789"}}}' \
    'JWT_SECRET_KEY holds a character that is not printable ASCII'
reject "secrets: that is no map" '{"kamerplanter": {"secrets": ["JWT_SECRET_KEY=x"]}}' 'kamerplanter: -> secrets: is not a map'
new_appliance
cloud_init nocloud iid-x "{\"kamerplanter\": {\"secrets\": {\"JWT_SECRET_KEY\": \"$map_jwt\\nDATA_DISK=/dev/sdb\"}}}"
run_step >/dev/null
expect "invalid map: the staged file holds one line for the entry, no injected one" "1|no" \
    "$(wc -l <"$SB/$staging/secrets.env")|$(has DATA_DISK=/dev/sdb "$(cat "$SB/$staging/secrets.env")")"

# reject_credential NAME VALUE MESSAGE: the credential JWT_SECRET_KEY with
# VALUE keeps the services stopped with MESSAGE, writing nothing.
reject_credential() {
    new_appliance
    printf '%b' "$2" >"$SB/creds/kamerplanter.secret.$4"
    local rc
    rc=$(run_configure)
    expect "invalid credential: $1" "1|yes|0" "$rc|$(has "$3" "$(out)")|$(wc -c <"$SB/etc/kamerplanter/secrets.env")"
}
reject_credential "a key that is not a secret" '/dev/disk/by-id/virtio-x' \
    'DATA_DISK in the system credential kamerplanter.secret.DATA_DISK is no secret the appliance takes over' DATA_DISK
reject_credential "a line break inside" "$cred_jwt\\nDATA_DISK=/dev/sdb" \
    'JWT_SECRET_KEY holds a character that is not printable ASCII, such as a line break (supplied by the system credential kamerplanter.secret.JWT_SECRET_KEY)' JWT_SECRET_KEY
reject_credential "a control character" "$cred_jwt\\x01" \
    'JWT_SECRET_KEY holds a character that is not printable ASCII (supplied by the system credential' JWT_SECRET_KEY
reject_credential "a NUL byte" "$cred_jwt\\x00tail" \
    'JWT_SECRET_KEY holds a character that is not printable ASCII (supplied by the system credential' JWT_SECRET_KEY
reject_credential "the upstream placeholder" change-me-in-production-use-openssl-rand-hex-32 \
    'JWT_SECRET_KEY is empty or the upstream placeholder (supplied by the system credential kamerplanter.secret.JWT_SECRET_KEY)' JWT_SECRET_KEY
reject_credential "longer than 4096 characters" "$(printf 'x%.0s' {1..4100})" \
    'JWT_SECRET_KEY is longer than 4096 characters' JWT_SECRET_KEY

# --- pinned values (L14, D12) ---
pin_of() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }
new_appliance
pin_of "$map_fernet" >"$SB/var/lib/kamerplanter/pinned/FERNET_KEY"
cloud_init nocloud iid-p "{\"kamerplanter\": {\"secrets\": {\"FERNET_KEY\": \"$map_fernet\"}}}"
run_step >/dev/null
expect "pinned: a provisioned value that matches the recorded one restores the missing key" "0|$map_fernet" \
    "$(run_configure)|$(secret FERNET_KEY)"
new_appliance
pin_of "$(fernet_of recorded)" >"$SB/var/lib/kamerplanter/pinned/FERNET_KEY"
cloud_init nocloud iid-p "{\"kamerplanter\": {\"secrets\": {\"FERNET_KEY\": \"$map_fernet\"}}}"
run_step >/dev/null
rc=$(run_configure)
expect "pinned: a differing one keeps the services stopped and is not written" "1|0|yes|yes" \
    "$rc|$(lines_of FERNET_KEY)|$(has 'FERNET_KEY from kamerplanter: -> secrets: of the provisioning data differs from the value Kamerplanter started with' "$(out)")|$(staged)"
printf 'FERNET_KEY=%s\n' "$(fernet_of recorded)" >"$SB/etc/kamerplanter/secrets.env"
rc=$(run_configure)
expect "pinned: once the key is restored from a backup, the services start and the map is recorded" "0|$(fernet_of recorded)|\"iid-p\"" \
    "$rc|$(secret FERNET_KEY)|$(record)"
new_appliance
pin_of "$(fernet_of recorded)" >"$SB/var/lib/kamerplanter/pinned/FERNET_KEY"
printf 'FERNET_KEY=%s\n' "$(fernet_of recorded)" >"$SB/etc/kamerplanter/kamerplanter.env"
credential FERNET_KEY "$map_fernet"
rc=$(run_configure)
expect "pinned: a differing one is not written where the user file holds the key; a warning, the services start" "0|0|yes" \
    "$rc|$(lines_of FERNET_KEY)|$(has 'warning: FERNET_KEY from the system credential kamerplanter.secret.FERNET_KEY differs from the value Kamerplanter started with; it is not taken over' "$(out)")"
new_appliance
pin_of "$(fernet_of recorded)" >"$SB/var/lib/kamerplanter/pinned/FERNET_KEY"
expect "pinned: without a provisioned value a missing pinned key still keeps the services stopped" "1|yes" \
    "$(run_configure)|$(has 'FERNET_KEY is missing from' "$(out)")"

# --- the step on unusual input ---
new_appliance
cloud_init nocloud iid-u '{"kamerplanter": '
expect "step: an unreadable combined cloud-config stages nothing" "0|no|yes" \
    "$(run_step)|$(staged)|$(has 'no provisioned secret is staged' "$(out)")"
new_appliance
mkdir -p "$SB/run/elsewhere"
ln -s "$SB/run/elsewhere" "$SB/$staging"
cloud_init nocloud iid-u "{\"kamerplanter\": {\"secrets\": {\"JWT_SECRET_KEY\": \"$map_jwt\"}}}"
expect "step: a staging place that is a symbolic link is not followed" "0|0|yes" \
    "$(run_step)|$(find "$SB/run/elsewhere" -type f | wc -l)|$(has 'is not a directory; no provisioned secret is staged' "$(out)")"
new_appliance
cloud_init nocloud iid-s "{\"kamerplanter\": {\"secrets\": {\"JWT_SECRET_KEY\": \"$map_jwt\"}}}"
run_step >/dev/null
mkdir -p "$SB/run/kamerplanter"
echo stale >"$SB/run/kamerplanter/app.env"
printf 'UPDATE_WINDOW=25:00\n' >"$SB/etc/kamerplanter/kamerplanter.env"
rc=$(run_configure)
expect "an invalid setting keeps the services stopped; the secret is taken over all the same and not staged again" "1|$map_jwt|no|no" \
    "$rc|$(secret JWT_SECRET_KEY)|$(staged)|$([ -e "$SB/run/kamerplanter/app.env" ] && echo yes || echo no)"

# --- the units (L13, L17) ---
units=$image/usr/lib/systemd/system
expect "units: the check imports the secret credentials, one per key" yes \
    "$(grep -qx 'ImportCredential=kamerplanter.secret.\*' "$units/kamerplanter-config.service" && echo yes)"
expect "units: the check runs after the data disk is in place and after the step" "yes|yes" \
    "$(grep -Eq '^Requires=.*\bkamerplanter-data-disk\.service\b' "$units/kamerplanter-config.service" && grep -Eq '^After=.*\bkamerplanter-data-disk\.service\b' "$units/kamerplanter-config.service" && echo yes)|$(grep -Eq '^After=.*\bkamerplanter-provisioning\.service\b' "$units/kamerplanter-config.service" && echo yes)"

# --- no value of a provisioned secret in any output (L12) ---
leaked=none
for m in "${markers[@]}"; do
    if grep -qF -- "$m" "$all_output"; then leaked=$m; fi
done
expect "no provisioned value in anything the step or the check printed" "none|yes" "$leaked|$([ -s "$all_output" ] && echo yes)"
expect "the host was not touched: every owner change the scripts asked for lies in a sandbox" no \
    "$(cat "$work"/appliance.*/chown-calls 2>/dev/null | grep -qv " $work/appliance\." && echo yes || echo no)"

if [ "$failures" -gt 0 ]; then
    echo "$failures check(s) failed"
    exit 1
fi
echo "all checks passed"
