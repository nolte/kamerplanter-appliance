#!/usr/bin/env bash
# Checks the provisioning layer (spec/distribution-requirements/ D11, L9-L11,
# L17, L19): its place and its order among the layers of
# image/rootfs/usr/lib/kamerplanter/env.sh, the provisioning step
# (image/rootfs/usr/libexec/kamerplanter/provisioning) on fake cloud-init
# output, the configuration check (configure), the update tool and the
# maintenance window generator reading the same layers, and the ordering of
# the units. The scripts run as they ship, in a sandbox (lib/sandbox.sh);
# needs no root, no cloud-init and no VM.
#
# Usage: tests/unit/provisioning.sh
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

# --- the layers and the place of the provisioning layer (D11, L10) ---
expect "layers: defaults, provisioning file, provisioning map, secrets, user file" \
    "/usr/share/kamerplanter/kamerplanter.env /var/lib/kamerplanter/provisioning/provisioning.env /var/lib/kamerplanter/provisioning/settings.env /etc/kamerplanter/secrets.env /etc/kamerplanter/kamerplanter.env" \
    "${config_layers[*]}"
expect "the write_files target of L9" /var/lib/kamerplanter/provisioning/provisioning.env "${provisioning_file-}"
inside=none
for place in "${data_disk_places[@]}" "x /etc/kamerplanter" "x /run/kamerplanter" "x $data_disk_mount"; do
    read -r _ path <<<"$place"
    case ${provisioning_dir-}/ in "$path"/*) inside=$path ;; esac
done
expect "the provisioning layer lies on the system disk's /var, in no location a data disk binds over, nor in /etc/kamerplanter or /run/kamerplanter" \
    "yes|none" "$(case ${provisioning_dir-} in /var/lib/kamerplanter/?*) echo yes ;; *) echo no ;; esac)|$inside"
expect "tmpfiles creates the layer's directory root only" yes \
    "$(grep -Eq '^d /var/lib/kamerplanter/provisioning 0700 root root ' "$image/usr/lib/tmpfiles.d/"*.conf && echo yes)"

# --- the loader: precedence and the keys the layer never sets (L9, L11, L19) ---
lt=$work/loader
mkdir -p "$lt"
(
    provisioning_file=$lt/provisioning.env provisioning_settings=$lt/settings.env
    provisioning_layer=("$provisioning_file" "$provisioning_settings")
    printf 'A=default\nB=default\nDATA_DISK=\n' >"$lt/defaults"
    printf 'A=file\nB=file\nDATA_DISK=/dev/disk/by-id/virtio-x\n' >"${provisioning_file-}"
    printf 'A=map\nBACKUP_DISK_FORCE=1\n' >"$provisioning_settings"
    printf 'DATA_DISK=/dev/disk/by-id/virtio-u\n' >"$lt/user"
    load "$lt/defaults" "${provisioning_layer[@]}" "$lt/user"
    printf '%s|%s|%s|%s|%s|%s\n' "$(get A)" "$(get B)" "$(get DATA_DISK)" "$(get BACKUP_DISK_FORCE)" \
        "${cfg_from[A]##*/}" "${cfg_ignored[*]//$lt\//}"
) >"$lt/out"
expect "loader: the map wins over the file, naming keys of the layer dropped, the user file still names" \
    "map|file|/dev/disk/by-id/virtio-u||settings.env|DATA_DISK provisioning.env BACKUP_DISK_FORCE settings.env" "$(cat "$lt/out")"

# --- the configuration check as it ships (configure) ---
# configure_case NAME: a fresh sandbox in SB with the image's defaults; the
# layers are written by the caller, then run_configure runs it.
configure_case() {
    SB=$(mktemp -d "$work/configure.XXXXXX")
    sandbox_install "$SB" "$image" /usr/libexec/kamerplanter/configure /usr/lib/kamerplanter/env.sh
    mkdir -p "$SB/usr/share/kamerplanter" "$SB/etc/kamerplanter" "$SB/var/lib/kamerplanter/disks" \
        "$SB/var/lib/kamerplanter/pinned" "$SB/var/lib/kamerplanter/provisioning" "$SB/var/mnt/kamerplanter-data" \
        "$SB/var/lib/containers/storage/volumes/arangodb_data" "$SB/var/lib/containers/storage/volumes/valkey_data"
    cp "$image/usr/share/kamerplanter/kamerplanter.env" "$SB/usr/share/kamerplanter/"
}
prov_file() { printf '%s\n' "$@" >"$SB/var/lib/kamerplanter/provisioning/provisioning.env"; }
prov_map() { printf '%s\n' "$@" >"$SB/var/lib/kamerplanter/provisioning/settings.env"; }
user_file() { printf '%s\n' "$@" >"$SB/etc/kamerplanter/kamerplanter.env"; }
run_configure() {  # prints the exit status; the output is in $SB/out
    (
        MOUNTED=
        sandbox_mounts
        bash "$SB/usr/libexec/kamerplanter/configure" >"$SB/out" 2>&1
        echo "$?"
    )
}
app() { sed -n "s/^$1=//p" "$SB/run/kamerplanter/app.env" 2>/dev/null; }  # app KEY: KEY as the services get it

configure_case
prov_map FRONTEND_URL=https://map.example.org KAMERPLANTER_MODE=full
expect "configure: a value of the map reaches the services" "0|https://map.example.org|full" \
    "$(run_configure)|$(app FRONTEND_URL)|$(app KAMERPLANTER_MODE)"

configure_case
prov_file FRONTEND_URL=https://file.example.org
expect "configure: a value only in the write_files file applies" "0|https://file.example.org" "$(run_configure)|$(app FRONTEND_URL)"

configure_case
prov_file FRONTEND_URL=https://file.example.org REGISTRATION_MODE=invite_only
prov_map FRONTEND_URL=https://map.example.org
expect "configure: for a key both set the map wins, the file's other keys stay" "0|https://map.example.org|invite_only" \
    "$(run_configure)|$(app FRONTEND_URL)|$(app REGISTRATION_MODE)"

configure_case
prov_file FRONTEND_URL=https://file.example.org REGISTRATION_MODE=invite_only
prov_map FRONTEND_URL=https://map.example.org
user_file FRONTEND_URL=https://user.example.org
expect "configure: the user file wins over the provisioning layer, which applies to the rest" "0|https://user.example.org|invite_only" \
    "$(run_configure)|$(app FRONTEND_URL)|$(app REGISTRATION_MODE)"

configure_case
jwt=$(printf 'p%.0s' {1..64})
prov_map "JWT_SECRET_KEY=$(printf 'm%.0s' {1..64})" FRONTEND_URL=https://map.example.org
printf 'JWT_SECRET_KEY=%s\n' "$jwt" >"$SB/etc/kamerplanter/secrets.env"
expect "configure: the secrets file wins over the provisioning layer (D11 order)" "0|$jwt|https://map.example.org" \
    "$(run_configure)|$(app JWT_SECRET_KEY)|$(app FRONTEND_URL)"

configure_case
prov_map UPDATE_WINDOW=25:00
rc=$(run_configure)
out=$(cat "$SB/out")
expect "configure: an invalid provisioned value keeps the services stopped" "1|no" "$rc|$([ -e "$SB/run/kamerplanter/app.env" ] && echo yes || echo no)"
expect "configure: the message names the value and the provisioning layer" yes \
    "$(has "UPDATE_WINDOW is not a time of day as HH:MM (the window starts at 03:00 until it is fixed) (set in the provisioning layer (kamerplanter: -> settings: of the provisioning data, in $SB/var/lib/kamerplanter/provisioning/settings.env))" "$out")"
expect "configure: the message format is kept, its advice names the provisioning data and the user file" "yes|yes" \
    "$(has 'Kamerplanter configuration is invalid; the services stay stopped:' "$out")|$(has "Fix a provisioned value in the provisioning data (kamerplanter: -> settings: is read again at the next boot; $SB/var/lib/kamerplanter/provisioning/provisioning.env is written once per instance and may be edited in place), or set it in $SB/etc/kamerplanter/kamerplanter.env, which wins over it" "$out")"

configure_case
prov_map UPDATE_WINDOW=25:00 FRONTEND_URL=https://map.example.org
user_file UPDATE_WINDOW=04:00
expect "configure: a value in the user file overrides an invalid provisioned one" "0|04:00|https://map.example.org" \
    "$(run_configure)|$(app UPDATE_WINDOW)|$(app FRONTEND_URL)"

configure_case
prov_map UPDATE_WINDOW=04:00 TENANT_EXPORT_SIGNING_SECRET=short
user_file UPDATE_WINDOW=25:00
run_configure >/dev/null
expect "configure: each message names the layer its value came from" "yes|yes" \
    "$(has 'TENANT_EXPORT_SIGNING_SECRET is set but shorter than 32 characters (set in the provisioning layer' "$(cat "$SB/out")")|$(grep -qx '  - UPDATE_WINDOW is not a time of day as HH:MM (the window starts at 03:00 until it is fixed)' "$SB/out" && echo yes)"

configure_case
prov_file 'not a setting'
expect "configure: a line of the write_files file that is not KEY=VALUE keeps the services stopped" 1 "$(run_configure)"
expect "configure: and names the line and the provisioning layer" yes \
    "$(has "line 1 of $SB/var/lib/kamerplanter/provisioning/provisioning.env is not KEY=VALUE, in the provisioning layer" "$(cat "$SB/out")")"

configure_case
prov_map DATA_DISK=/dev/sdb DATA_DISK_FORCE=yes BACKUP_DISK=/dev/sdc FRONTEND_URL=https://map.example.org
rc=$(run_configure)
out=$(cat "$SB/out")
expect "configure: naming keys of the provisioning layer are ignored, not checked (L19)" "0||0|https://map.example.org" \
    "$rc|$(app DATA_DISK)|$(app DATA_DISK_FORCE)|$(app FRONTEND_URL)"
expect "configure: each ignored key is reported with where to set it instead, never its value" "yes|yes|yes|no" \
    "$(has 'DATA_DISK in the provisioning layer (kamerplanter: -> settings: of the provisioning data' "$out")|$(has 'kamerplanter/disks name data PATH [force], or as the system credential kamerplanter.data-disk-force' "$out")|$(has 'BACKUP_DISK in the provisioning layer' "$out")|$(has /dev/sdb "$out")"

configure_case
fernet=$(head -c 32 /dev/urandom | base64 | tr '+/' '-_')
prov_map "FERNET_KEY=$fernet"
rc=$(run_configure)
out=$(cat "$SB/out")
expect "configure: a secret under settings: is used" "0|$fernet" "$rc|$(app FERNET_KEY)"
expect "configure: and warned about, naming the key and secrets:, not the value" "yes|yes|no" \
    "$(has 'warning: the secret FERNET_KEY is set in the provisioning layer' "$out")|$(has 'kamerplanter: -> secrets:' "$out")|$(has "$fernet" "$out")"
expect "configure: no FERNET_KEY is generated beside the provisioned one (L14)" 0 "$(grep -c '^FERNET_KEY=' "$SB/etc/kamerplanter/secrets.env")"

configure_case
prov_file "FERNET_KEY=$fernet"
other=$(head -c 32 /dev/urandom | base64 | tr '+/' '-_')
printf 'FERNET_KEY=%s\n' "$other" >"$SB/etc/kamerplanter/secrets.env"
rc=$(run_configure)
out=$(cat "$SB/out")
expect "configure: a provisioned secret that the secrets file overrides is warned about all the same" "0|$other|yes|no|no" \
    "$rc|$(app FERNET_KEY)|$(has "warning: the secret FERNET_KEY is set in the provisioning layer ($SB/var/lib/kamerplanter/provisioning/provisioning.env)" "$out")|$(has "$fernet" "$out")|$(has "$other" "$out")"

configure_case
prov_map FRONTEND_URL=https://map.example.org
expect "configure: no warning without a secret in the layer" "0|https://map.example.org|no" \
    "$(run_configure)|$(app FRONTEND_URL)|$(has warning "$(cat "$SB/out")")"

# --- the other readers load the same layers (L10) ---
# reader_case: a sandbox for the update tool and the window generator with
# UPDATE_WINDOW and UPDATE_HEALTH_TIMEOUT set in the layers given.
reader_case() {  # reader_case FILE_LINES MAP_LINES USER_LINES
    SB=$(mktemp -d "$work/reader.XXXXXX")
    sandbox_install "$SB" "$image" /usr/bin/kamerplanter-update /usr/lib/kamerplanter/env.sh \
        /usr/lib/systemd/system-generators/kamerplanter-update-window
    mkdir -p "$SB/usr/share/kamerplanter" "$SB/etc/kamerplanter" "$SB/var/lib/kamerplanter/provisioning"
    cp "$image/usr/share/kamerplanter/kamerplanter.env" "$SB/usr/share/kamerplanter/"
    printf '%b' "$1" >"$SB/var/lib/kamerplanter/provisioning/provisioning.env"
    printf '%b' "$2" >"$SB/var/lib/kamerplanter/provisioning/settings.env"
    printf '%b' "$3" >"$SB/etc/kamerplanter/kamerplanter.env"
}
window() {  # the window the sandboxed generator sets
    bash "$SB/usr/lib/systemd/system-generators/kamerplanter-update-window" "$SB/gen" &&
        sed -n 's/^OnCalendar=\*-\*-\* \(.*\):00$/\1/p' "$SB/gen/kamerplanter-update-apply.timer.d/50-window.conf"
}
count_of() {  # count_of KEY DEFAULT: count() of the sandboxed update tool
    (
        # shellcheck source=/dev/null
        . "$SB/usr/lib/kamerplanter/env.sh"
        eval "$(sed -n '/^count() {/,/^}/p' "$SB/usr/bin/kamerplanter-update")"
        count "$@"
    )
}
reader_case 'UPDATE_WINDOW=01:15\nUPDATE_HEALTH_TIMEOUT=31\n' '' ''
expect "readers: the write_files file sets the window and the health timeout" "01:15|31" "$(window)|$(count_of UPDATE_HEALTH_TIMEOUT 20)"
reader_case 'UPDATE_WINDOW=01:15\nUPDATE_HEALTH_TIMEOUT=31\n' 'UPDATE_WINDOW=02:45\nUPDATE_HEALTH_TIMEOUT=41\n' ''
expect "readers: the map wins in the generator and the update tool" "02:45|41" "$(window)|$(count_of UPDATE_HEALTH_TIMEOUT 20)"
reader_case '' 'UPDATE_WINDOW=02:45\nUPDATE_HEALTH_TIMEOUT=41\n' 'UPDATE_WINDOW=05:05\nUPDATE_HEALTH_TIMEOUT=51\n'
expect "readers: the user file wins in the generator and the update tool" "05:05|51" "$(window)|$(count_of UPDATE_HEALTH_TIMEOUT 20)"
reader_case '' 'UPDATE_WINDOW=25:00\nUPDATE_HEALTH_TIMEOUT=x\n' ''
expect "readers: an invalid provisioned value falls back to the default" "03:00|20" "$(window)|$(count_of UPDATE_HEALTH_TIMEOUT 20)"

# --- the provisioning step as it ships (provisioning) ---
# step_case: a sandbox for the step with cloud-init's run directory; the
# generator is a stub writing $SB/window, and systemctl notes its calls.
step_case() {
    SB=$(mktemp -d "$work/step.XXXXXX")
    sandbox_install "$SB" "$image" /usr/libexec/kamerplanter/provisioning /usr/lib/kamerplanter/env.sh
    mkdir -p "$SB/run/cloud-init" "$SB/var/lib/kamerplanter" "$SB/usr/lib/systemd/system-generators" \
        "$SB/run/systemd/generator/kamerplanter-update-apply.timer.d"
    echo 03:00 >"$SB/window"
    printf '[Timer]\nOnCalendar=*-*-* 03:00:00\n' >"$SB/run/systemd/generator/kamerplanter-update-apply.timer.d/50-window.conf"
    cat >"$SB/usr/lib/systemd/system-generators/kamerplanter-update-window" <<EOF
#!/usr/bin/bash
mkdir -p "\$1/kamerplanter-update-apply.timer.d"
printf '[Timer]\\nOnCalendar=*-*-* %s:00\\n' "\$(cat "$SB/window")" >"\$1/kamerplanter-update-apply.timer.d/50-window.conf"
EOF
    chmod 0755 "$SB/usr/lib/systemd/system-generators/kamerplanter-update-window"
}
cloud_init() {  # cloud_init PLATFORM CLOUD_CONFIG_JSON: what cloud-init leaves in /run on a boot it runs
    printf '{"v1": {"platform": "%s"}}\n' "$1" >"$SB/run/cloud-init/instance-data.json"
    printf '%s\n' "$2" >"$SB/run/cloud-init/combined-cloud-config.json"
}
# The commands that reach the system, as the step calls them. Owner root is
# what the step enforces; as any user it is noted only. The step reloads
# through timeout, which would run the real systemctl.
chown() { echo "chown $*" >>"$SB/chown-calls"; }
systemctl() { echo "systemctl $*" >>"$SB/systemctl-calls"; }
timeout() { shift; "$@"; }
run_step() {  # prints the exit status; the output is in $SB/out
    (
        export SB
        export -f chown systemctl timeout
        bash "$SB/usr/libexec/kamerplanter/provisioning" >"$SB/out" 2>&1
        echo "$?"
    )
}
layer() { grep -v '^#' "$SB/var/lib/kamerplanter/provisioning/settings.env" 2>/dev/null | paste -sd'|'; }
mode() { stat -c %a "$1" 2>/dev/null; }

step_case
cloud_init nocloud '{"kamerplanter": {"settings": {"FRONTEND_URL": "https://map.example.org", "UPDATE_HEALTH_TIMEOUT": 30, "DEBUG": false, "CORS_ORIGINS": "[\"https://a.example.org\"]", "EMPTY": null}, "secrets": {"FERNET_KEY": "marker-secret-value"}}}'
expect "step: the map becomes the layer, one KEY=VALUE per entry" \
    '0|FRONTEND_URL=https://map.example.org|UPDATE_HEALTH_TIMEOUT=30|DEBUG=false|CORS_ORIGINS=["https://a.example.org"]|EMPTY=' \
    "$(run_step)|$(layer)"
expect "step: the layer is root only, 0600 in a directory of 0700" "600|700|yes" \
    "$(mode "$SB/var/lib/kamerplanter/provisioning/settings.env")|$(mode "$SB/var/lib/kamerplanter/provisioning")|$(grep -q "chown root:root $SB/var/lib/kamerplanter/provisioning/settings.env" "$SB/chown-calls" && echo yes)"
expect "step: kamerplanter: -> secrets: is not written into the layer, nor printed (L12)" "yes|no|no" \
    "$(has FRONTEND_URL "$(cat "$SB/var/lib/kamerplanter/provisioning/settings.env" 2>/dev/null)")|$(has marker-secret-value "$(cat "$SB/var/lib/kamerplanter/provisioning/settings.env" 2>/dev/null)")|$(has marker-secret-value "$(cat "$SB/out")")"
expect "step: no value is printed, the same window reloads nothing" "no|yes|no" \
    "$(has map.example.org "$(cat "$SB/out")")|$(has 'renewed from the provisioning data: 5 entries' "$(cat "$SB/out")")|$([ -e "$SB/systemctl-calls" ] && echo yes || echo no)"

step_case
mkdir -m 0755 "$SB/var/lib/kamerplanter/provisioning"
printf 'FRONTEND_URL=https://file.example.org\n' >"$SB/var/lib/kamerplanter/provisioning/provisioning.env"
chmod 0644 "$SB/var/lib/kamerplanter/provisioning/provisioning.env"
cloud_init nocloud '{"kamerplanter": {"settings": {}}}'
expect "step: write_files' file and directory are made root only, the file is kept" "0|600|700|FRONTEND_URL=https://file.example.org" \
    "$(run_step)|$(mode "$SB/var/lib/kamerplanter/provisioning/provisioning.env")|$(mode "$SB/var/lib/kamerplanter/provisioning")|$(cat "$SB/var/lib/kamerplanter/provisioning/provisioning.env")"
expect "step: an empty map renews the layer to empty" "yes|" "$(has 'renewed from the provisioning data: 0 entries' "$(cat "$SB/out")")|$(layer)"

# A boot without provisioning data keeps the layer of the last boot with it.
step_case
cloud_init nocloud '{"kamerplanter": {"settings": {"FRONTEND_URL": "https://old.example.org"}}}'
run_step >/dev/null
before=$(cat "$SB/var/lib/kamerplanter/provisioning/settings.env")
rm -f "$SB/run/cloud-init/"*
expect "step: cloud-init disabled (no data): the layer is kept" "0|$before|yes" \
    "$(run_step)|$(cat "$SB/var/lib/kamerplanter/provisioning/settings.env")|$(has 'no provisioning data on this boot' "$(cat "$SB/out")")"
cloud_init none '{"kamerplanter": {"settings": {}}}'
expect "step: cloud-init fell back to the datasource None: the layer is kept" "0|$before|yes" \
    "$(run_step)|$(cat "$SB/var/lib/kamerplanter/provisioning/settings.env")|$(has 'no provisioning data on this boot' "$(cat "$SB/out")")"
cloud_init nocloud '{"kamerplanter": '
expect "step: an unreadable combined cloud-config: the layer is kept" "0|$before|yes" \
    "$(run_step)|$(cat "$SB/var/lib/kamerplanter/provisioning/settings.env")|$(has 'cannot be read' "$(cat "$SB/out")")"
cloud_init nocloud '{"kamerplanter": {"settings": {"FRONTEND_URL": "https://new.example.org"}}}'
expect "step: a changed map applies on the next boot with data" "0|FRONTEND_URL=https://new.example.org" "$(run_step)|$(layer)"
cloud_init nocloud '{"hostname": "kp"}'
expect "step: data without kamerplanter: empties the layer" "0||yes" "$(run_step)|$(layer)|$(has '0 entries' "$(cat "$SB/out")")"

# Entries that cannot be a line of the layer: the configuration check names them.
step_case
cloud_init nocloud '{"kamerplanter": {"settings": {"bad-key": "x", "LIST": [1], "LINES": "a\nINJECTED=1", "OK": "fine"}}}'
run_step >/dev/null
expect "step: invalid entries become lines that are not KEY=VALUE, never two lines" \
    'invalid entry of kamerplanter: -> settings:, the key "bad-key" is no KEY name|invalid entry of kamerplanter: -> settings:, the value of LIST is a array, not a single value|invalid entry of kamerplanter: -> settings:, the value of LINES spans several lines|OK=fine' \
    "$(layer)"
mkdir -p "$SB/usr/share/kamerplanter" "$SB/etc/kamerplanter" "$SB/var/lib/kamerplanter/pinned" "$SB/var/mnt/kamerplanter-data"
cp "$image/usr/share/kamerplanter/kamerplanter.env" "$SB/usr/share/kamerplanter/"
sandbox_install "$SB" "$image" /usr/libexec/kamerplanter/configure
expect "step then configure: an invalid entry keeps the services stopped, naming the provisioning layer" "1|yes|no" \
    "$(run_configure)|$(has "line 4 of $SB/var/lib/kamerplanter/provisioning/settings.env is not KEY=VALUE, in the provisioning layer" "$(cat "$SB/out")")|$(has INJECTED "$(cat "$SB/out")")"
step_case
cloud_init nocloud '{"kamerplanter": {"settings": ["FRONTEND_URL=x"]}}'
run_step >/dev/null
expect "step: settings: that is no map becomes one invalid line" 'invalid entry of the provisioning data: kamerplanter: -> settings: is not a map' "$(layer)"

# The maintenance window (L17): reloaded when the layer changes it, on
# every boot, also without data.
step_case
cloud_init nocloud '{"kamerplanter": {"settings": {"UPDATE_WINDOW": "04:30"}}}'
echo 04:30 >"$SB/window"
expect "step: a provisioned window that differs reloads systemd" "0|systemctl daemon-reload" "$(run_step)|$(cat "$SB/systemctl-calls" 2>/dev/null)"
expect "step: and says so" yes "$(has 'maintenance window reloaded' "$(cat "$SB/out")")"
rm -f "$SB/run/cloud-init/"* "$SB/systemctl-calls"
expect "step: a later boot without data reloads as well, for the kept layer" "0|systemctl daemon-reload" "$(run_step)|$(cat "$SB/systemctl-calls" 2>/dev/null)"
printf '[Timer]\nOnCalendar=*-*-* 04:30:00\n' >"$SB/run/systemd/generator/kamerplanter-update-apply.timer.d/50-window.conf"
rm -f "$SB/systemctl-calls"
expect "step: no reload when the generator saw the window already" "0||UPDATE_WINDOW=04:30" \
    "$(run_step)|$(cat "$SB/systemctl-calls" 2>/dev/null)|$(layer)"

# --- ordering of the units (L17) ---
units=$image/usr/lib/systemd/system
expect "units: the configuration check runs after the provisioning step and not when it failed" "yes|yes" \
    "$(grep -Eq '^After=.*\bkamerplanter-provisioning\.service\b' "$units/kamerplanter-config.service" && echo yes)|$(grep -Eq '^Requires=.*\bkamerplanter-provisioning\.service\b' "$units/kamerplanter-config.service" && echo yes || echo no)"
expect "units: the step is ordered after cloud-init's network stage and never pulls cloud-init in" "yes|no" \
    "$(grep -Eq '^After=.*\bcloud-init-network\.service\b' "$units/kamerplanter-provisioning.service" 2>/dev/null && echo yes)|$(grep -Eq '^(Requires|Wants|Requisite|BindsTo)=.*cloud' "$units/kamerplanter-provisioning.service" 2>/dev/null && echo yes || echo no)"
expect "units: the step is started with the services and enabled in the image" "yes|yes" \
    "$(grep -qx 'WantedBy=kamerplanter.target' "$units/kamerplanter-provisioning.service" && echo yes)|$(grep -q 'kamerplanter-provisioning.service' "$root/image/Containerfile" && echo yes)"

if [ "$failures" -gt 0 ]; then
    echo "$failures check(s) failed"
    exit 1
fi
echo "all checks passed"
