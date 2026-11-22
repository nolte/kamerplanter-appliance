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
reject "a JWT_SECRET_KEY below 32 characters (D12)" '{"kamerplanter": {"secrets": {"JWT_SECRET_KEY": "only-thirty-one-characters-long"}}}' \
    'JWT_SECRET_KEY is shorter than 32 characters (supplied by kamerplanter: -> secrets:'
reject "an ARANGODB_PASSWORD below 16 characters (D12)" '{"kamerplanter": {"secrets": {"ARANGODB_PASSWORD": "fifteen-chars-x"}}}' \
    'ARANGODB_PASSWORD is shorter than 16 characters (supplied by kamerplanter: -> secrets:'
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
reject_credential "a JWT_SECRET_KEY below 32 characters (D12)" 'only-thirty-one-characters-long' \
    'JWT_SECRET_KEY is shorter than 32 characters (supplied by the system credential kamerplanter.secret.JWT_SECRET_KEY)' JWT_SECRET_KEY
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

# --- keyed pins and the migration of legacy ones (D12, #56) ---
# The pins written before were the plain SHA-256 of the value (pin_of
# above); they are checked as they are, and replaced by the HMAC-SHA256 keyed
# with the device's key once the value matches.
pins_dir() { printf '%s' "$SB/var/lib/kamerplanter/pinned"; }
pin_key() { cat "$(pins_dir)/.key" 2>/dev/null; }
hmac_of() {  # hmac_of KEY_HEX VALUE: the reference HMAC-SHA256, computed independently of configure
    K=$1 V=$2 python3 -c 'import hashlib, hmac, os; print(hmac.new(bytes.fromhex(os.environ["K"]), os.environ["V"].encode(), hashlib.sha256).hexdigest())'
}
run_pin() {  # run_pin KEY...: configure pin, as a service runs it before it starts
    (
        MOUNTED=
        sandbox_mounts
        export SB
        export -f chown systemctl timeout
        bash "$SB/usr/libexec/kamerplanter/configure" pin "$@" >"$SB/out" 2>&1
        echo "$?"
    )
    cat "$SB/out" >>"$all_output"
}
exists() { [ -e "$1" ] && echo yes || echo no; }
keys=()

new_appliance
rc=$(run_configure)
keys+=("$(pin_key)")
expect "keyed: the first run generates the key of the pins, 32 random bytes, 0600, before any pin" "0|yes|600|no" \
    "$rc|$([[ $(pin_key) =~ ^[0-9a-f]{64}$ ]] && echo yes)|$(mode "$(pins_dir)/.key")|$(compgen -G "$(pins_dir)/*" >/dev/null && echo yes || echo no)"
rc=$(run_pin FERNET_KEY ERASURE_TOMBSTONE_SALT)
expect "keyed: a service pins the HMAC of the value with the key, no legacy pin, 0600" "0|yes|yes|no|600" \
    "$rc|$([ "$(cat "$(pins_dir)/FERNET_KEY.hmac")" = "$(hmac_of "$(pin_key)" "$(secret FERNET_KEY)")" ] && echo yes)|$([ "$(cat "$(pins_dir)/ERASURE_TOMBSTONE_SALT.hmac")" = "$(hmac_of "$(pin_key)" "$(secret ERASURE_TOMBSTONE_SALT)")" ] && echo yes)|$(exists "$(pins_dir)/FERNET_KEY")|$(mode "$(pins_dir)/FERNET_KEY.hmac")"
before=$(cat "$(pins_dir)/FERNET_KEY.hmac")
reboot
expect "keyed: the same value passes, the pin and the key stay as they are" "0|yes|${keys[0]}" \
    "$(run_configure)|$([ "$(cat "$(pins_dir)/FERNET_KEY.hmac")" = "$before" ] && echo yes)|$(pin_key)"
expect "keyed: pinning again leaves a recorded pin as it is" "0|yes" \
    "$(run_pin FERNET_KEY)|$([ "$(cat "$(pins_dir)/FERNET_KEY.hmac")" = "$before" ] && echo yes)"
sed -i "s/^FERNET_KEY=.*/FERNET_KEY=$(fernet_of changed)/" "$SB/etc/kamerplanter/secrets.env"
rc=$(run_configure)
expect "keyed: a changed value keeps the services stopped and names the pin to remove" "1|yes|no" \
    "$rc|$(has "FERNET_KEY differs from the value Kamerplanter started with: stored credentials are encrypted with it and become unreadable (then remove $(pins_dir)/FERNET_KEY.hmac)" "$(out)")|$(exists "$SB/run/kamerplanter/app.env")"
sed -i '/^FERNET_KEY=/d' "$SB/etc/kamerplanter/secrets.env"
expect "keyed: a missing pinned value is not generated again" "1|yes|0" \
    "$(run_configure)|$(has 'FERNET_KEY is missing from' "$(out)")|$(lines_of FERNET_KEY)"

# A keyed pin without its key cannot be checked: the services stay
# stopped, and no new key is made that could never match.
new_appliance
run_configure >/dev/null
run_pin FERNET_KEY >/dev/null
keys+=("$(pin_key)")
rm "$(pins_dir)/.key"
rc=$(run_pin ERASURE_TOMBSTONE_SALT)
expect "keyed: a keyed pin whose key is gone: pinning another value makes no new key that could never match" "1|yes|no|no" \
    "$rc|$(has "not pinning ERASURE_TOMBSTONE_SALT: the key of the pins" "$(out)")|$(exists "$(pins_dir)/.key")|$(exists "$(pins_dir)/ERASURE_TOMBSTONE_SALT.hmac")"
rc=$(run_configure)
expect "keyed: and the check keeps the services stopped" "1|yes|no|no" \
    "$rc|$(has "the key of the pins, $(pins_dir)/.key, is missing or damaged although keyed pins are recorded" "$(out)")|$(exists "$(pins_dir)/.key")|$(exists "$SB/run/kamerplanter/app.env")"
echo damaged >"$(pins_dir)/.key"
expect "keyed: a damaged key is the same" "1|damaged" "$(run_configure)|$(pin_key)"

# A pin that is a link leading nowhere is recorded, not missing: the
# services stay stopped and the message names it, the value is not pinned
# anew, and a missing value is not generated again.
new_appliance
run_configure >/dev/null
run_pin FERNET_KEY >/dev/null
keys+=("$(pin_key)")
rm "$(pins_dir)/FERNET_KEY.hmac"
ln -s "$work/nowhere" "$(pins_dir)/FERNET_KEY.hmac"
reboot
rc=$(run_configure)
expect "keyed: a pin that is a link leading nowhere keeps the services stopped and names it" "1|yes|no" \
    "$rc|$(has "the pin of FERNET_KEY is a link that leads nowhere, so the value Kamerplanter started with cannot be checked: restore the pin from your backup, or, when the value of FERNET_KEY is the one Kamerplanter started with, remove $(pins_dir)/FERNET_KEY.hmac and restart" "$(out)")|$(exists "$SB/run/kamerplanter/app.env")"
expect "keyed: pinning leaves such a link as it is" "0|yes" \
    "$(run_pin FERNET_KEY)|$([ -L "$(pins_dir)/FERNET_KEY.hmac" ] && [ ! -e "$(pins_dir)/FERNET_KEY.hmac" ] && echo yes)"
sed -i '/^FERNET_KEY=/d' "$SB/etc/kamerplanter/secrets.env"
expect "keyed: and a missing value pinned by such a link is not generated again" "1|yes|0" \
    "$(run_configure)|$(has 'FERNET_KEY is missing from' "$(out)")|$(lines_of FERNET_KEY)"

# Two runs that find a damaged key take turns: the one that waits for the
# lock looks at the key again and pins with the key the other one made,
# instead of replacing it under the pin that other one wrote.
new_appliance
run_configure >/dev/null
echo damaged >"$(pins_dir)/.key"
other_key=$(printf 'ab%.0s' {1..32})
rm -f "$work/held" "$work/release"
# shellcheck disable=SC2016 # expanded by the holder, from its arguments
flock "$SB/run/kamerplanter-pins.lock" bash -c '
    touch "$3/held"
    while [ ! -e "$3/release" ]; do sleep 0.1; done
    printf "%s\n" "$2" >"$1/var/lib/kamerplanter/pinned/.key"' _ "$SB" "$other_key" "$work" &
holder=$!
for _ in $(seq 100); do [ -e "$work/held" ] && break; sleep 0.1; done
run_pin FERNET_KEY >"$work/pin-rc" &
pinner=$!
# Released only once the pinner waits for the lock (its flock is running),
# so the case also fails where a run does not wait at all.
waited=no
for _ in $(seq 100); do
    if pgrep -f "^flock -w 30 " >/dev/null; then waited=yes; break; fi
    sleep 0.1
done
touch "$work/release"
wait "$holder"
wait "$pinner"
keys+=("$(pin_key)")
expect "keyed: a run that waited for the lock pins with the key the other run made, and keeps it" "yes|0|$other_key|yes" \
    "$waited|$(cat "$work/pin-rc")|$(pin_key)|$([ "$(cat "$(pins_dir)/FERNET_KEY.hmac" 2>/dev/null)" = "$(hmac_of "$other_key" "$(secret FERNET_KEY)")" ] && echo yes)"

# --- an upgraded installation: legacy pins are migrated, nothing stops ---
new_appliance
run_configure >/dev/null
rm "$(pins_dir)/.key"   # as on a release before: no key yet
pin_of "$(secret FERNET_KEY)" >"$(pins_dir)/FERNET_KEY"
pin_of "$(secret ERASURE_TOMBSTONE_SALT)" >"$(pins_dir)/ERASURE_TOMBSTONE_SALT"
reboot
rc=$(run_configure)
keys+=("$(pin_key)")
expect "migration: matching legacy pins become keyed ones, the services start" "0|yes|yes|no|no|yes" \
    "$rc|$([ "$(cat "$(pins_dir)/FERNET_KEY.hmac" 2>/dev/null)" = "$(hmac_of "$(pin_key)" "$(secret FERNET_KEY)")" ] && echo yes)|$([ "$(cat "$(pins_dir)/ERASURE_TOMBSTONE_SALT.hmac" 2>/dev/null)" = "$(hmac_of "$(pin_key)" "$(secret ERASURE_TOMBSTONE_SALT)")" ] && echo yes)|$(exists "$(pins_dir)/FERNET_KEY")|$(exists "$(pins_dir)/ERASURE_TOMBSTONE_SALT")|$(exists "$SB/run/kamerplanter/app.env")"
expect "migration: says so by key, without a warning" "yes|no" \
    "$(has "the pin of FERNET_KEY is now keyed: $(pins_dir)/FERNET_KEY.hmac replaces $(pins_dir)/FERNET_KEY" "$(out)")|$(has warning "$(out)")"
# While an update is being checked, the legacy pin stays for the release an
# automatic rollback would return to; it goes once the update is decided.
new_appliance
run_configure >/dev/null
rm "$(pins_dir)/.key"
pin_of "$(secret FERNET_KEY)" >"$(pins_dir)/FERNET_KEY"
mkdir -p "$SB/var/lib/kamerplanter/update"
echo "sha256:a sha256:b checking" >"$SB/var/lib/kamerplanter/update/pending"
reboot
rc=$(run_configure)
keys+=("$(pin_key)")
expect "migration: during the check of an update the keyed pin is written and the legacy one kept" "0|yes|yes|yes" \
    "$rc|$(exists "$(pins_dir)/FERNET_KEY")|$([ "$(cat "$(pins_dir)/FERNET_KEY.hmac" 2>/dev/null)" = "$(hmac_of "$(pin_key)" "$(secret FERNET_KEY)")" ] && echo yes)|$(has "$(pins_dir)/FERNET_KEY is kept until the update being checked is decided" "$(out)")"
before=$(cat "$(pins_dir)/FERNET_KEY.hmac")
rm "$SB/var/lib/kamerplanter/update/pending"
reboot
expect "migration: once the update is decided, the legacy pin is deleted, the keyed one stays" "0|no|yes" \
    "$(run_configure)|$(exists "$(pins_dir)/FERNET_KEY")|$([ "$(cat "$(pins_dir)/FERNET_KEY.hmac")" = "$before" ] && echo yes)"
# An empty record of the update being checked, as a write cut short leaves
# it, is none, as for kamerplanter-update: the legacy pin goes.
new_appliance
run_configure >/dev/null
rm "$(pins_dir)/.key"
pin_of "$(secret FERNET_KEY)" >"$(pins_dir)/FERNET_KEY"
mkdir -p "$SB/var/lib/kamerplanter/update"
: >"$SB/var/lib/kamerplanter/update/pending"
reboot
rc=$(run_configure)
keys+=("$(pin_key)")
expect "migration: an empty record of an update being checked is none: the legacy pin is deleted" "0|no|yes|yes" \
    "$rc|$(exists "$(pins_dir)/FERNET_KEY")|$([ "$(cat "$(pins_dir)/FERNET_KEY.hmac" 2>/dev/null)" = "$(hmac_of "$(pin_key)" "$(secret FERNET_KEY)")" ] && echo yes)|$(has "the pin of FERNET_KEY is now keyed" "$(out)")"

# A later rollback to a release before: it reads only the legacy file, finds none,
# and pins the value again in the old form when its service starts. Back on
# this release, both are checked and the legacy one migrated again.
pin_of "$(secret FERNET_KEY)" >"$(pins_dir)/FERNET_KEY"
reboot
expect "migration: after a rollback and an update again, both pins are checked and the legacy one migrated" "0|no|yes" \
    "$(run_configure)|$(exists "$(pins_dir)/FERNET_KEY")|$([ "$(cat "$(pins_dir)/FERNET_KEY.hmac")" = "$(hmac_of "$(pin_key)" "$(secret FERNET_KEY)")" ] && echo yes)"
pin_of "$(fernet_of elsewhere)" >"$(pins_dir)/FERNET_KEY"
reboot
expect "migration: a legacy pin that differs, beside a matching keyed one, keeps the services stopped and names both" "1|yes|yes" \
    "$(run_configure)|$(has "(then remove $(pins_dir)/FERNET_KEY.hmac and $(pins_dir)/FERNET_KEY)" "$(out)")|$(exists "$(pins_dir)/FERNET_KEY")"
# A value changed on a release before after a rollback, as its docs say
# (delete the legacy pin, restart): that release pins the new value in the
# old form, beside the keyed pin of the old one. Back on this release the
# legacy pin decides; the stale keyed pin is written anew, nothing stops,
# so the update does not fail its health check and roll back again.
sed -i "s/^FERNET_KEY=.*/FERNET_KEY=$(fernet_of rotated)/" "$SB/etc/kamerplanter/secrets.env"
pin_of "$(secret FERNET_KEY)" >"$(pins_dir)/FERNET_KEY"
reboot
rc=$(run_configure)
expect "migration: a stale keyed pin beside a matching legacy one is written anew, the services start" "0|yes|no|yes|yes" \
    "$rc|$([ "$(cat "$(pins_dir)/FERNET_KEY.hmac")" = "$(hmac_of "$(pin_key)" "$(fernet_of rotated)")" ] && echo yes)|$(exists "$(pins_dir)/FERNET_KEY")|$(exists "$SB/run/kamerplanter/app.env")|$(has "the keyed pin of FERNET_KEY was older than $(pins_dir)/FERNET_KEY" "$(out)")"
# A keyed pin that is a link leading nowhere beside a legacy one: the legacy
# pin decides. Matching, the keyed pin is written anew and nothing stops;
# differing, the message is that of a changed value, not of a pin that cannot
# be checked (whose advice would pin the changed value).
pin_of "$(secret FERNET_KEY)" >"$(pins_dir)/FERNET_KEY"
rm "$(pins_dir)/FERNET_KEY.hmac"
ln -s "$work/nowhere" "$(pins_dir)/FERNET_KEY.hmac"
mkdir -p "$SB/var/lib/kamerplanter/update"
echo "sha256:a sha256:b checking" >"$SB/var/lib/kamerplanter/update/pending"
reboot
rc=$(run_configure)
expect "migration: a keyed pin leading nowhere beside a matching legacy one is written anew, the services start" "0|yes|yes|yes" \
    "$rc|$([ ! -L "$(pins_dir)/FERNET_KEY.hmac" ] && [ "$(cat "$(pins_dir)/FERNET_KEY.hmac")" = "$(hmac_of "$(pin_key)" "$(secret FERNET_KEY)")" ] && echo yes)|$(exists "$SB/run/kamerplanter/app.env")|$(has "the keyed pin of FERNET_KEY was a link that leads nowhere" "$(out)")"
rm "$(pins_dir)/FERNET_KEY.hmac"
ln -s "$work/nowhere" "$(pins_dir)/FERNET_KEY.hmac"
pin_of "$(fernet_of elsewhere)" >"$(pins_dir)/FERNET_KEY"
reboot
rc=$(run_configure)
expect "migration: a differing legacy pin beside a keyed pin leading nowhere is a changed value" "1|yes|no" \
    "$rc|$(has "FERNET_KEY differs from the value Kamerplanter started with" "$(out)")|$(has "leads nowhere" "$(out)")"
rm "$SB/var/lib/kamerplanter/update/pending"

new_appliance
run_configure >/dev/null
rm "$(pins_dir)/.key"
pin_of "$(fernet_of recorded)" >"$(pins_dir)/FERNET_KEY"
reboot
rc=$(run_configure)
expect "migration: a legacy pin that differs keeps the services stopped as before; nothing is migrated" "1|yes|yes|no" \
    "$rc|$(has "FERNET_KEY differs from the value Kamerplanter started with: stored credentials are encrypted with it and become unreadable (then remove $(pins_dir)/FERNET_KEY)" "$(out)")|$(exists "$(pins_dir)/FERNET_KEY")|$(exists "$(pins_dir)/FERNET_KEY.hmac")"

# A provisioned value of a key with a keyed pin (L14): restored only when it
# matches.
new_appliance
run_configure >/dev/null
printf 'FERNET_KEY=%s\n' "$map_fernet" >"$SB/etc/kamerplanter/secrets.env"
reboot
run_configure >/dev/null
run_pin FERNET_KEY >/dev/null
keys+=("$(pin_key)")
sed -i '/^FERNET_KEY=/d' "$SB/etc/kamerplanter/secrets.env"
reboot
cloud_init nocloud iid-k "{\"kamerplanter\": {\"secrets\": {\"FERNET_KEY\": \"$map_fernet\"}}}"
run_step >/dev/null
expect "keyed: a provisioned value that matches the keyed pin restores the missing key" "0|$map_fernet" \
    "$(run_configure)|$(secret FERNET_KEY)"
sed -i '/^FERNET_KEY=/d' "$SB/etc/kamerplanter/secrets.env"
reboot
credential FERNET_KEY "$(fernet_of other)"
expect "keyed: one that differs keeps the services stopped and is not written" "1|0|yes" \
    "$(run_configure)|$(lines_of FERNET_KEY)|$(has 'FERNET_KEY from the system credential kamerplanter.secret.FERNET_KEY differs from the value Kamerplanter started with' "$(out)")"

leaked=none
for k in "${keys[@]}"; do
    if [ -n "$k" ] && grep -qF -- "$k" "$all_output"; then leaked=$k; fi
done
expect "keyed: no key of the pins in anything the check printed" "none|8" "$leaked|${#keys[@]}"

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
