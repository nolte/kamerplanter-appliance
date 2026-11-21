#!/usr/bin/env bash
# Boot tests with a data disk (spec/distribution-requirements/ E6-E16,
# requirement R18 of project/requirements/data-disk.md). Runs inside the tool
# container (see build/in-tools.sh), after `task image:build` and
# `task disk:build`.
#
# The appliance under test is a release: the variant "next" of
# tests/boot/variants with the release version 1.1.0, built on the image under
# test and written to its own disk, since a development build never marks a
# data disk (E13). The development build of `task disk:build` plays the older
# system in the downgrade step. The disks are qcow2 files attached as
# virtio-blk with a serial, named to the appliance by the credential
# kamerplanter.data-disk (/dev/disk/by-id/virtio-SERIAL); a disk is attached
# to a running VM through QEMU's monitor. The guests have no internet access:
# every container image comes with the disk.
#
#   tests/boot/data-disk.sh [step ...]   (default: all steps)
#
# Steps, in order, each needing the ones before it unless it says otherwise:
#   build    the release image and its disk (d0)
#   none     no data disk; the baseline of SELinux denials (d1)
#   move     moving that running appliance onto a newly named disk, the health
#            check from it, and the deletion of the system disk's copy (d4)
#   data     a fresh appliance with a blank data disk (d2)
#   replace  a fresh appliance of the same release on the same disk: data,
#            logins and encrypted fields kept (d3)
#   missing  the same appliance without its disk, then with it again (d5)
#   downgrade  an older system on the disk: refused, then allowed (d6)
#   luks     an encrypted data disk with its key from a credential (d7)
#   backup   a backup disk next to the data disk (d8)
#
# shellcheck disable=SC2016,SC2329
# SC2016: guest commands are single-quoted on purpose; they expand in the guest.
# SC2329: the step_* functions are dispatched by name at the bottom.
set -uo pipefail

WORK=.build/data-disk
mkdir -p "$WORK"
# Set again after run.sh, which resolves it, so that it never falls back to
# the development build's disk while this one does not exist yet.
export DISK=$PWD/$WORK/disk.raw
# shellcheck source=/dev/null
source "$(dirname "$0")/run.sh"
DISK=$PWD/$WORK/disk.raw
RESULTS=$OUT/data-disk-results.tsv

BASE=${IMAGE_REF:-localhost/kamerplanter-appliance:poc}
RELEASE=1.1.0
RELEASE_IMAGE=localhost/kamerplanter-appliance:test-data-disk
DEV_DISK=$PWD/.build/disk.raw
# shellcheck disable=SC2034 # read by start_vm and monitor in run.sh
VM_MONITOR=10044
API=http://127.0.0.1:18000/api/v1
# A test account in a throwaway VM.
EMAIL=data-disk@example.org
PASSWORD=Data-Disk-Test-1234
MNT=/var/mnt/kamerplanter-data
VOLUME=/var/lib/containers/storage/volumes/arangodb_data/_data
# Where each test disk is attached: its serial and file.
declare -A SERIAL=([data]=kpdata [move]=kpmove [luks]=kpluks [backup]=kpbackup)

by_id() { echo "/dev/disk/by-id/virtio-${SERIAL[$1]}"; }
disk_file() { echo "$PWD/$WORK/$1.qcow2"; }
blank_disk() { rm -f "$(disk_file "$1")"; qemu-img create -q -f qcow2 "$(disk_file "$1")" "${2:-4G}"; }
overlay_of() { qemu-img create -q -f qcow2 -F raw -b "$1" "$2" 20G; }
with_disk() { VM_DISKS+=("${SERIAL[$1]} $(disk_file "$1")"); }
named() { VM_CREDENTIALS+=("kamerplanter.data-disk $(by_id "$1")"); }
reset_extras() { VM_DISKS=() VM_CREDENTIALS=(); }

# attach ROLE / detach ROLE: plugs the disk into the running VM, or out of it.
attach() {
    monitor "drive_add 0 if=none,id=h$1,file=$(disk_file "$1"),format=qcow2" \
        "device_add virtio-blk-pci,drive=h$1,id=hdev$1,serial=${SERIAL[$1]}"
}

fail() { diagnose "$1"; record "$1" FAIL - "$2"; }

# boot_up NAME TIMEOUT: prints the seconds until web UI and API answer.
boot_up() {
    local secs
    secs=$(wait_up "$2") || { fail "$1" "web UI and API did not answer within $2s"; return 1; }
    echo "$secs"
}

# reboot_guest: reboots and waits for the new boot to be up; prints seconds.
reboot_guest() {
    local id start=$SECONDS new
    id=$(guest cat /proc/sys/kernel/random/boot_id)
    guest systemctl reboot >/dev/null 2>&1
    while ((SECONDS - start < REBOOT_TIMEOUT)); do
        new=$(guest cat /proc/sys/kernel/random/boot_id 2>/dev/null) && [ -n "$new" ] && [ "$new" != "$id" ] && break
        vm_alive || return 2
        sleep 5
    done
    wait_up "$REBOOT_TIMEOUT" >/dev/null || return 1
    echo $((SECONDS - start))
}

# Units that must not run while the data disk is not in place.
stopped_services() {
    guest '! systemctl is-active -q kamerplanter-config.service && ! systemctl is-active -q kamerplanter-arangodb.service &&
        ! systemctl is-active -q kamerplanter-backend.service'
}

# avc_records: the SELinux denials of this boot as the journal has them, with
# the name of the file, the source context and the process.
avc_records() {
    guest 'journalctl -b -k -g "avc:  denied" --no-pager -o cat 2>/dev/null; journalctl -b _TRANSPORT=audit -g "avc:  denied" --no-pager -o cat 2>/dev/null'
}

# avc_signatures [FILE]: the SELinux denials of this boot (or those recorded
# in FILE), one signature per line: command, permission, class and target
# type, without the probe bootc runs on every `bootc status` (an invalid label
# it expects to be refused).
avc_signatures() {
    if [ -n "${1-}" ]; then cat "$1"; else avc_records; fi |
        sed -n 's/.*denied  { \([^}]*\) }.*comm="\([^"]*\)".*tcontext=[^:]*:[^:]*:\([^:]*\):.*tclass=\([a-z_0-9]*\).*/\2 \1 \4 \3/p' |
        sed 's/  */ /g' | sort -u
}

# new_avcs NAME: the denials of this boot that the boot without a data disk
# did not have; written to NAME.avc.txt, and every denial record of this boot
# to NAME.avc-records.txt, so that a failure names the file and the process
# (#94). Both go into the run's artifacts.
# Without the baseline every check would pass unseen: a run that leaves out
# the step none (CI splits the steps into jobs) reports that as a denial.
new_avcs() {
    avc_records >"$OUT/$1.avc-records.txt"
    if [ ! -f "$WORK/avc-baseline.txt" ]; then
        echo "no baseline of SELinux denials: run the step none before" | tee "$OUT/$1.avc.txt"
        return
    fi
    avc_signatures "$OUT/$1.avc-records.txt" | comm -23 - "$WORK/avc-baseline.txt" >"$OUT/$1.avc.txt"
    cat "$OUT/$1.avc.txt"
}

# placed_checks NAME [moved]: the checks of a data disk in place (P4): every
# location bound from the disk, SELinux labels as the policy wants them, no
# denial beyond the baseline, ArangoDB running on the disk's volume, the
# modes of the secrets; and, unless the data was just moved there at runtime,
# the disk service done before every reader and no secret on the system disk.
placed_checks() {
    local name=$1 out
    out=$(guest "MOVED=${2-} bash -s" <<'EOS' 2>&1
set -u
problems=()
mnt=/var/mnt/kamerplanter-data
src=$(findmnt -rnvo SOURCE -M "$mnt")
[ -n "$src" ] || problems+=("$mnt not mounted")
for path in /etc/kamerplanter /var/lib/kamerplanter/pinned \
    /var/lib/containers/storage/volumes/arangodb_data /var/lib/containers/storage/volumes/valkey_data; do
    [ "$(findmnt -rnvo SOURCE -M "$path")" = "$src" ] || problems+=("$path not bound from $src")
done
findmnt -rno OPTIONS -M "$mnt" | grep -q 'nosuid,nodev,noexec' || problems+=("$mnt lacks nosuid,nodev,noexec")
relabel=$(restorecon -nRv /etc/kamerplanter /var/lib/kamerplanter/pinned \
    /var/lib/containers/storage/volumes/arangodb_data /var/lib/containers/storage/volumes/valkey_data 2>&1 |
    grep -v 'not reset as customized by admin')
[ -z "$relabel" ] || problems+=("labels differ from the policy: ${relabel//$'\n'/; }")
[ "$(stat -c %C /var/lib/containers/storage/volumes/arangodb_data/_data | cut -d: -f3)" = container_file_t ] ||
    problems+=("arangodb _data is not container_file_t")
# Ordering: the disk service is done before any reader starts.
done_at=$(systemctl show -P ActiveEnterTimestampMonotonic kamerplanter-data-disk.service)
for unit in kamerplanter-update-guard.service kamerplanter-config.service arangodb-volume.service \
    valkey-volume.service kamerplanter-arangodb.service; do
    [ -z "$MOVED" ] || break
    started=$(systemctl show -P InactiveExitTimestampMonotonic "$unit")
    [ "$started" -ge "$done_at" ] || problems+=("$unit started before the data disk was in place")
done
[ "$(podman --storage-opt=additionalimagestore=/usr/lib/bootc/storage inspect --format '{{.State.Health.Status}}' arangodb)" = healthy ] ||
    problems+=("arangodb not healthy")
[ -n "$(ls -A "$mnt/volumes/arangodb_data/_data" 2>/dev/null)" ] || problems+=("no ArangoDB files on the disk")
[ -s "$mnt/etc/secrets.env" ] || problems+=("no secrets.env on the disk")
# The system disk holds no secret: neither under the bind nor in a
# deployment. After a move it does until the cleanup (d4-cleanup).
if [ -z "$MOVED" ]; then
    leftover=$(unshare -m sh -c 'umount /etc/kamerplanter && ls -A /etc/kamerplanter' 2>&1)
    case $leftover in *secrets.env*) problems+=("secrets.env on the system disk under the bind") ;; esac
    for d in /sysroot/ostree/deploy/*/deploy/*/etc/kamerplanter; do
        [ ! -e "$d/secrets.env" ] || problems+=("secrets.env in $d")
    done
fi
[ "$(stat -c %a "$mnt/etc")" = 700 ] && [ "$(stat -c %a "$mnt/etc/secrets.env")" = 600 ] ||
    problems+=("modes of etc/secrets.env are not 0700/0600")
printf '%s\n' "${problems[@]}"
EOS
    )
    local avcs
    avcs=$(new_avcs "$name")
    [ -z "$avcs" ] || out+=$'\n'"new SELinux denials: ${avcs//$'\n'/; }"
    out=$(sed '/^$/d' <<<"$out")
    if [ -n "$out" ]; then
        fail "$name" "${out//$'\n'/; }"
        return 1
    fi
}

# shutdown_problems: stuck or failed unmounts and closes in the journal of the
# previous boot, and the disk service stopped before a database.
shutdown_problems() {
    guest bash -s <<'EOS'
journalctl -b -1 --no-pager -o cat | grep -E 'could not be unmounted|could not be closed|still mounted|Failed unmounting|Unmounting timed out|kamerplanter-(data|backup)-disk.service: (Failed|State .stop-sigterm. timed out)' | sort -u
last() { journalctl -b -1 --no-pager -o short-monotonic | grep -F "$1" | tail -n1 | sed 's/^\[ *\([0-9.]*\)\].*/\1/'; }
disk=$(last 'Stopped kamerplanter-data-disk.service')
for unit in kamerplanter-arangodb.service kamerplanter-valkey.service; do
    stopped=$(last "Stopped $unit")
    [ -z "$disk" ] || [ -z "$stopped" ] || awk -v d="$disk" -v s="$stopped" 'BEGIN { exit !(d < s) }' &&
        echo "kamerplanter-data-disk.service stopped before $unit"
done
EOS
}

# --- API: a login and a Fernet-encrypted setting ---------------------------

login() {
    curl -s --max-time 10 -X POST "$API/auth/login" -H 'content-type: application/json' \
        -d "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\"}" | jq -r '.access_token // empty'
}
# authorized TOKEN: the API takes the token.
authorized() { [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H "Authorization: Bearer $1" "$API/users/me")" = 200 ]; }
# The global OpenWeatherMap key, which the backend stores Fernet-encrypted
# with FERNET_KEY, as the backend decrypts it, and whether it is stored as a
# Fernet token at all.
stored_secret() {
    guest "podman exec backend python -W ignore -c 'from app.common.dependencies import get_weather_settings_service as g
s = g()
print(\"token\" if (s._stored().openweathermap_global_api_key_encrypted or \"\").startswith(\"gAAAAA\") else \"plain\")
print(s.get_effective_weather_settings().openweathermap_global_api_key)' 2>/dev/null"
}

secrets_sum() { guest "sha256sum <$MNT/etc/secrets.env | cut -d' ' -f1"; }
marker() { guest "cat $MNT/release 2>/dev/null"; }

# Until the health service has raised the marker of the disk to the release.
wait_marker() {
    local start=$SECONDS
    while ((SECONDS - start < $1)); do
        [ "$(marker)" = "$2" ] && return 0
        sleep 10
    done
    return 1
}

# --- steps -----------------------------------------------------------------

# The release on its own disk, rebuilt only when the image under test changed.
step_build() {
    local id
    podman build --quiet -t "$RELEASE_IMAGE" --build-arg BASE="$BASE" --build-arg VARIANT=next \
        --build-arg VERSION="$RELEASE" tests/boot/variants >/dev/null ||
        { record d0 FAIL - "build of the release image failed"; return 1; }
    id=$(podman image inspect --format '{{.Id}}' "$RELEASE_IMAGE")
    if [ -f "$DISK" ] && [ "$(cat "$WORK/disk.image-id" 2>/dev/null)" = "$id" ]; then
        record d0 PASS - "release $RELEASE disk up to date"
        return 0
    fi
    local start=$SECONDS
    DISK_OUT=$DISK build/disk.sh "$RELEASE_IMAGE" >"$OUT/d0.disk.log" 2>&1 ||
        { record d0 FAIL - "disk build failed, see d0.disk.log"; return 1; }
    echo "$id" >"$WORK/disk.image-id"
    record d0 PASS "$((SECONDS - start))s" "release $RELEASE built on the image under test, disk written"
}

# R18 (1): no data disk. Also the denials every boot has, for comparison.
step_none() {
    reset_extras
    overlay_of "$DISK" "$WORK/d1.qcow2"
    start_vm d1 bios virtio-scsi virtio off "$WORK/d1.qcow2" || { record d1 FAIL - "qemu did not start"; return 1; }
    local secs
    secs=$(boot_up d1 "$FIRST_BOOT_TIMEOUT") || return 1
    avc_records >"$OUT/d1.avc-records.txt"
    avc_signatures "$OUT/d1.avc-records.txt" >"$WORK/avc-baseline.txt"
    cp "$WORK/avc-baseline.txt" "$OUT/d1.avc-baseline.txt"
    local status
    status=$(guest /usr/libexec/kamerplanter/disks status)
    if ! grep -qx 'data disk: not set up' <<<"$status" ||
        guest "findmnt -rn $MNT >/dev/null || findmnt -rn /etc/kamerplanter >/dev/null"; then
        fail d1 "a data disk is in place without being named: ${status//$'\n'/; }"
        return 1
    fi
    record d1 PASS "${secs}s" "no data disk: first boot from the system disk, nothing mounted or bound ($(wc -l <"$WORK/avc-baseline.txt") baseline denial signatures)"
    # P8: the guard reads another deployment's features file; on composefs
    # the deployment trees under /sysroot are plain directories.
    local features
    features=$(guest 'root=$(bootc status --format=json | jq -r ".status.booted.ostree | \"/sysroot/ostree/deploy/\(.stateroot)/deploy/\(.checksum).\(.deploySerial)\"")
        grep -x backup-locations "$root/usr/lib/kamerplanter/features" && findmnt -rno FSTYPE /')
    if grep -qx backup-locations <<<"$features"; then
        record d1-features PASS - "the booted deployment's /usr/lib/kamerplanter/features is readable under /sysroot (root fs ${features##*$'\n'})"
    else
        record d1-features FAIL - "features not readable from the deployment tree: ${features//$'\n'/; }"
    fi
}

# R18 (4): the running appliance of d1 is moved onto a newly named disk
# (E11), checked from it, and the system disk's copy deleted.
step_move() {
    vm_alive || { record d4 SKIP - "needs the running VM of d1"; return 1; }
    guest "touch $VOLUME/WRITTEN_BEFORE_MOVE"
    local before
    before=$(guest 'sha256sum </etc/kamerplanter/secrets.env | cut -d" " -f1')
    blank_disk move
    attach move || { record d4 FAIL - "the disk could not be attached"; return 1; }
    guest "udevadm settle; test -e $(by_id move)" || { fail d4 "$(by_id move) did not appear"; return 1; }
    local start=$SECONDS secs
    # Named in the user file, then moved without a reboot (docs: P10).
    guest "echo DATA_DISK=$(by_id move) >>/etc/kamerplanter/kamerplanter.env &&
        echo UPDATE_BACKUP_KEEP_DAYS=1 >>/etc/kamerplanter/kamerplanter.env &&
        systemctl restart kamerplanter-data-disk.service" >"$OUT/d4.restart.txt" 2>&1
    guest 'systemctl start kamerplanter.target' >/dev/null 2>&1
    secs=$(boot_up d4 "$REBOOT_TIMEOUT") || return 1
    local state waited=0
    until state=$(guest '. /usr/lib/kamerplanter/env.sh; data_disk_move_field STATE') && [ "$state" = verified ] ||
        ((waited >= 1500)); do
        sleep 10; waited=$((waited + 10))
    done
    guest /usr/libexec/kamerplanter/disks status >"$OUT/d4.status.txt" 2>&1
    if [ "$state" != verified ]; then
        fail d4 "the move did not reach verified (state $state)"
        return 1
    fi
    if ! guest "test -e $MNT/volumes/arangodb_data/_data/WRITTEN_BEFORE_MOVE" ||
        [ "$(secrets_sum)" != "$before" ]; then
        fail d4 "the data on the disk is not the data of the system disk"
        return 1
    fi
    placed_checks d4 moved || return 1
    record d4 PASS "$((SECONDS - start))s" "running appliance moved onto newly named $(by_id move) by a restart of the disk unit, healthy from it (verified), same secrets and volume data, binds and labels in place (E11)"
    # The copy on the system disk goes UPDATE_BACKUP_KEEP_DAYS after the
    # check, at the daily run of the fetch unit (cleanup); the check is moved
    # four days back instead of waiting (the 1 set above counts as the
    # minimum of 3 days, keep_days in env.sh).
    guest "sed -i 's/^VERIFIED=.*/VERIFIED=$(date -u -d '-4 days' +%FT%TZ)/' /var/lib/kamerplanter/disks/move.env &&
        systemctl start kamerplanter-update-fetch.service" >"$OUT/d4.cleanup.txt" 2>&1
    local left problems
    state=$(guest '. /usr/lib/kamerplanter/env.sh; data_disk_move_field STATE')
    left=$(guest 'ls -A /sysroot/ostree/deploy/*/deploy/*/etc/kamerplanter/; unshare -m sh -c "umount /etc/kamerplanter && ls -A /etc/kamerplanter"' 2>&1)
    problems=$(new_avcs d4-cleanup)
    if [ "$state" = cleaned ] && [ -z "$(sed '/^\//d;/^$/d' <<<"$left")" ] && [ -z "$problems" ] &&
        guest 'findmnt -rno OPTIONS -M /sysroot | grep -q "^ro,"'; then
        record d4-cleanup PASS - "system disk's copy deleted by kamerplanter-update-fetch.service (unshare, /sysroot rw only in its namespace, ro outside), no new SELinux denial"
    else
        fail d4-cleanup "state=$state left=[${left//$'\n'/ }] denials=[${problems//$'\n'/; }]"
    fi
    wait_up "$REBOOT_TIMEOUT" >/dev/null || fail d4-cleanup "services not up after the cleanup"
    stop_vm
}

# R18 (2): a fresh appliance with a blank, named data disk.
step_data() {
    reset_extras
    blank_disk data
    with_disk data
    named data
    overlay_of "$DISK" "$WORK/d2.qcow2"
    start_vm d2 bios virtio-scsi virtio off "$WORK/d2.qcow2" || { record d2 FAIL - "qemu did not start"; return 1; }
    local secs
    secs=$(boot_up d2 "$FIRST_BOOT_TIMEOUT") || return 1
    if ! guest "journalctl -b -u kamerplanter-data-disk.service -o cat | grep -F 'formatted: $(by_id data)'" >/dev/null; then
        fail d2 "the disk named by the SMBIOS credential was not formatted"
        return 1
    fi
    placed_checks d2 || return 1
    wait_marker 1500 "$RELEASE" || { fail d2 "the release marker was not raised to $RELEASE (it holds '$(marker)')"; return 1; }
    record d2 PASS "${secs}s" "blank disk named by SMBIOS credential formatted, binds and labels in place, no new denial, disk service before every reader, ArangoDB on it, no secret on the system disk, marker $RELEASE after the health check"
    # Data to keep: an encrypted setting, an account, a file in the volume,
    # and a maintenance window only the disk's user file sets.
    date +%s%N | sha256sum | cut -c1-24 >"$WORK/sentinel"
    curl -sf -o /dev/null --max-time 10 -X PUT "$API/admin/weather-providers" -H 'content-type: application/json' \
        -d "{\"openweathermap_global_api_key\":\"$(cat "$WORK/sentinel")\"}" || { fail d2-data "the encrypted setting could not be stored"; return 1; }
    guest "touch $VOLUME/WRITTEN_ON_D2
        echo UPDATE_WINDOW=04:44 >>/etc/kamerplanter/kamerplanter.env
        echo KAMERPLANTER_MODE=full >>/etc/kamerplanter/kamerplanter.env
        systemctl restart kamerplanter.target"
    sleep 10
    wait_up "$REBOOT_TIMEOUT" >/dev/null || { fail d2-data "services did not come back in full mode"; return 1; }
    curl -sf -o /dev/null --max-time 10 -X POST "$API/auth/register" -H 'content-type: application/json' \
        -d "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\",\"display_name\":\"Data disk\"}" ||
        { fail d2-data "registration failed"; return 1; }
    local token
    token=$(login)
    if [ -z "$token" ] || ! authorized "$token"; then fail d2-data "login failed"; return 1; fi
    echo "$token" >"$WORK/token"
    secrets_sum >"$WORK/secrets.sum"
    [ "$(stored_secret)" = "token"$'\n'"$(cat "$WORK/sentinel")" ] || { fail d2-data "the setting is not stored as a Fernet token"; return 1; }
    record d2-data PASS - "encrypted setting stored as Fernet token, account registered and logged in (full mode set in the disk's user file)"
    # Reboot: the disk service and its binds stop after the databases, the
    # window comes from the disk.
    if ! secs=$(reboot_guest); then fail d2-reboot "no answer after the reboot"; return 1; fi
    local problems window
    problems=$(shutdown_problems)
    window=$(guest systemctl show kamerplanter-update-apply.timer -p TimersCalendar --value)
    if [ -n "$problems" ]; then
        fail d2-reboot "shutdown: ${problems//$'\n'/; }"
    elif [[ $window != *04:44:00* ]]; then
        fail d2-reboot "TimersCalendar is '$window', not the disk's 04:44"
    else
        record d2-reboot PASS "${secs}s" "reboot: no stuck unmount, disk service stopped after the databases; TimersCalendar after boot $window from the disk's user file"
    fi
    guest "journalctl -b -1 --no-pager -o short-monotonic | grep -E 'kamerplanter|Unmount|unmount' | tail -n 80" >"$OUT/d2.shutdown.txt" 2>&1
    stop_vm
}

# R18 (3): a fresh appliance of the same release on the same disk (E8, E10).
step_replace() {
    [ -f "$(disk_file data)" ] && [ -f "$WORK/token" ] || { record d3 SKIP - "needs the disk of d2"; return 1; }
    reset_extras
    with_disk data
    named data
    rm -f "$WORK/d3.qcow2"
    overlay_of "$DISK" "$WORK/d3.qcow2"
    start_vm d3 bios virtio-scsi virtio off "$WORK/d3.qcow2" || { record d3 FAIL - "qemu did not start"; return 1; }
    local secs token problems=()
    secs=$(boot_up d3 "$FIRST_BOOT_TIMEOUT") || return 1
    guest "journalctl -b -u kamerplanter-data-disk.service -o cat | grep -F adopted" >/dev/null ||
        problems+=("the disk was not adopted")
    [ "$(secrets_sum)" = "$(cat "$WORK/secrets.sum")" ] || problems+=("secrets.env differs")
    authorized "$(cat "$WORK/token")" || problems+=("the token issued before is refused")
    token=$(login)
    { [ -n "$token" ] && authorized "$token"; } || problems+=("login with the account failed")
    [ "$(stored_secret)" = "token"$'\n'"$(cat "$WORK/sentinel")" ] || problems+=("the encrypted setting cannot be read")
    guest "test -e $VOLUME/WRITTEN_ON_D2" || problems+=("the volume lost its file")
    [ "$(marker)" = "$RELEASE" ] || problems+=("marker '$(marker)', not $RELEASE")
    if [ ${#problems[@]} -gt 0 ]; then
        fail d3 "$(IFS=';'; echo "${problems[*]}")"
        return 1
    fi
    placed_checks d3 || return 1
    record d3 PASS "${secs}s" "fresh appliance of $RELEASE adopted the disk: same secrets, old token and new login accepted, Fernet setting decrypted, volume data and marker kept, no secret on the system disk"
    stop_vm
}

# R18 (5): the appliance of d3 without its disk (E12), then with it again.
step_missing() {
    [ -f "$WORK/d3.qcow2" ] || { record d5 SKIP - "needs the appliance of d3"; return 1; }
    reset_extras
    start_vm d5 bios virtio-scsi virtio off "$WORK/d3.qcow2" || { record d5 FAIL - "qemu did not start"; return 1; }
    # The disk service waits for the disk, then fails. settled alone does not
    # tell: before sshd answers, list-jobs reads as empty.
    local start=$SECONDS state
    until state=$(guest systemctl show -P ActiveState kamerplanter-data-disk.service 2>/dev/null) &&
        { [ "$state" = failed ] || [ "$state" = active ]; } && settled ||
        ((SECONDS - start > REBOOT_TIMEOUT)); do sleep 5; done
    local problems=() issue
    [ "$state" = failed ] || problems+=("the disk service did not fail")
    stopped_services || problems+=("services run without the disk")
    issue=$(guest 'cat /run/issue.d/40-kamerplanter-data-disk.issue')
    grep -q kp-data <<<"$issue" || problems+=("the console message does not name kp-data")
    guest 'test ! -e /etc/kamerplanter/secrets.env && test ! -e /run/kamerplanter/app.env' || problems+=("secrets were generated on the system disk")
    echo "$issue" >"$OUT/d5.issue.txt"
    if [ ${#problems[@]} -gt 0 ]; then
        fail d5 "$(IFS=';'; echo "${problems[*]}")"
        return 1
    fi
    record d5 PASS "$((SECONDS - start))s" "without the disk: disk service failed after its wait, services stopped, console names kp-data (${issue%%$'\n'*}), no secret on the system disk"
    # Written by the disk service, which can start before systemd-tmpfiles.
    check_console d5-console 40-kamerplanter-data-disk.issue
    attach data || { fail d5-back "the disk could not be attached"; return 1; }
    guest "udevadm settle; systemctl restart kamerplanter.target"
    local secs
    if secs=$(wait_up "$REBOOT_TIMEOUT") && [ "$(secrets_sum)" = "$(cat "$WORK/secrets.sum")" ]; then
        record d5-back PASS "${secs}s" "disk plugged in, systemctl restart kamerplanter.target: services up on the disk's secrets"
    else
        fail d5-back "services did not start after the disk was back"
    fi
    stop_vm
}

# R18 (6): an older system (the development build) on the disk the release
# marked (E13): refused, then started by the override.
step_downgrade() {
    [ -f "$(disk_file data)" ] && [ "$(cat "$WORK/token" 2>/dev/null)" ] || { record d6 SKIP - "needs the disk of d2"; return 1; }
    reset_extras
    with_disk data
    named data
    overlay_of "$DEV_DISK" "$WORK/d6.qcow2"
    start_vm d6 bios virtio-scsi virtio off "$WORK/d6.qcow2" || { record d6 FAIL - "qemu did not start"; return 1; }
    local start=$SECONDS
    until [ "$(guest systemctl show -P ActiveState kamerplanter-update-guard.service 2>/dev/null)" = failed ] && settled ||
        ((SECONDS - start > FIRST_BOOT_TIMEOUT)); do sleep 5; done
    local problems=() issue running
    running=$(guest "bootc status --format=json | jq -r '.status.booted.image.version // \"unversioned\"'")
    guest systemctl is-failed -q kamerplanter-update-guard.service || problems+=("the guard did not fail")
    stopped_services || problems+=("services run on the newer release's disk")
    issue=$(guest 'cat /run/issue.d/45-kamerplanter-release.issue')
    { grep -qF "$RELEASE" <<<"$issue" && grep -qF "allow-downgrade" <<<"$issue"; } || problems+=("the console message lacks the release or the override")
    echo "$issue" >"$OUT/d6.issue.txt"
    if [ ${#problems[@]} -gt 0 ]; then
        fail d6 "$(IFS=';'; echo "${problems[*]}")"
        return 1
    fi
    record d6 PASS - "development build ($running) on the disk of $RELEASE: guard failed, services stopped, console: ${issue%%$'\n'*}"
    # Written by the update guard, which can start before systemd-tmpfiles.
    check_console d6-console 45-kamerplanter-release.issue
    local secs
    guest "kamerplanter-update allow-downgrade $RELEASE $running </dev/null" >"$OUT/d6.allow.txt" 2>&1 ||
        { fail d6-allow "allow-downgrade refused: $(tail -n1 "$OUT/d6.allow.txt")"; return 1; }
    if ! secs=$(wait_up "$REBOOT_TIMEOUT"); then fail d6-allow "services did not start after the override"; return 1; fi
    if ! authorized "$(login)" || [ "$(marker)" != "$RELEASE" ]; then
        fail d6-allow "after the override: login or marker wrong (marker '$(marker)')"
        return 1
    fi
    if ! secs=$(reboot_guest); then fail d6-allow "no answer after a reboot with the override"; return 1; fi
    record d6-allow PASS "${secs}s" "kamerplanter-update allow-downgrade $RELEASE $running restarted kamerplanter.target, services up, login works, marker stays $RELEASE; holds across a reboot"
    stop_vm
}

# Extra: an encrypted data disk, its key from a binary SMBIOS credential (E14).
# The key exists only in this shell and the VM's command line.
step_luks() {
    reset_extras
    blank_disk luks
    with_disk luks
    named luks
    local key
    key=$(head -c 64 /dev/urandom | base64 -w0)
    VM_CREDENTIALS+=("binary:kamerplanter.data-disk-key $key")
    overlay_of "$DISK" "$WORK/d7.qcow2"
    start_vm d7 bios virtio-scsi virtio off "$WORK/d7.qcow2" || { record d7 FAIL - "qemu did not start"; return 1; }
    local secs problems=()
    secs=$(boot_up d7 "$FIRST_BOOT_TIMEOUT") || return 1
    guest 'grep -qx ENCRYPTION=luks2 /var/lib/kamerplanter/disks/data.env' || problems+=("record lacks ENCRYPTION=luks2")
    guest "[ \"\$(findmnt -rnvo SOURCE -M $MNT)\" = /dev/mapper/kamerplanter-data ]" || problems+=("not mounted from the mapper")
    guest '[ "$(stat -c %a /var/lib/kamerplanter/disks/keys)" = 700 ] && [ "$(stat -c %a /var/lib/kamerplanter/disks/keys/data.key)" = 600 ]' ||
        problems+=("stored key modes are not 0700/0600")
    # The key goes to the guest on stdin, never on a command line, which the
    # audit log would record.
    printf '%s\n' "$key" | guest "umask 077; cat >/run/p9-key; trap 'rm -f /run/p9-key' EXIT
        journalctl -b --no-pager -o cat | grep -qFf /run/p9-key || grep -rqFf /run/p9-key $MNT /var/log 2>/dev/null" &&
        problems+=("the key appears in the journal or on the disk")
    if [ ${#problems[@]} -gt 0 ]; then fail d7 "$(IFS=';'; echo "${problems[*]}")"; return 1; fi
    placed_checks d7 || return 1
    local pbkdf unlock
    pbkdf=$(guest "cryptsetup luksDump $(by_id luks) | sed -n 's/^\s*PBKDF:\s*//p;s/^\s*Memory:\s*//p;s/^\s*Time cost:\s*//p' | head -n3 | paste -sd' '")
    unlock=$(guest "s=\$(date +%s%N); cryptsetup open --test-passphrase --key-file /var/lib/kamerplanter/disks/keys/data.key $(by_id luks) && echo \$(( (\$(date +%s%N) - s) / 1000000 ))ms")
    record d7 PASS "${secs}s" "blank disk with key credential: LUKS2 set up, mounted from the mapper, key stored 0600 in 0700, key not in journal or on the disk; PBKDF $pbkdf, unlock with the stored key $unlock (2 vCPU)"
    # Without the credential: opened with the stored key.
    stop_vm
    reset_extras
    with_disk luks
    named luks
    start_vm d7b bios virtio-scsi virtio off "$WORK/d7.qcow2" || { record d7-reboot FAIL - "qemu did not start"; return 1; }
    secs=$(boot_up d7-reboot "$REBOOT_TIMEOUT") || return 1
    local took
    took=$(guest 'a=$(systemctl show -P ExecMainStartTimestampMonotonic kamerplanter-data-disk.service); b=$(systemctl show -P ActiveEnterTimestampMonotonic kamerplanter-data-disk.service); echo $(( (b - a) / 1000 ))ms')
    record d7-reboot PASS "${secs}s" "boot without the key credential: opened with the stored key; the disk service took $took (unlock, check, mount, binds)"
    stop_vm
    reset_extras
    start_vm d7c bios virtio-scsi virtio off "$WORK/d7.qcow2" || return 1
    secs=0
    until guest true || ((secs > 300)); do sleep 5; secs=$((secs + 5)); done
    local closes
    closes=$(guest "journalctl -b -1 --no-pager -o cat | grep -E 'kp-data disk closed|is still mounted|could not be closed' | sort -u")
    if grep -q 'kp-data disk closed' <<<"$closes" && ! grep -qE 'still mounted|could not be closed' <<<"$closes"; then
        record d7-shutdown PASS - "shutdown of the encrypted disk: unbound, unmounted, mapper closed"
    else
        record d7-shutdown FAIL - "shutdown of the encrypted disk: ${closes//$'\n'/; }"
    fi
    stop_vm
}

# Extra: a backup disk named next to the data disk of d3, set up at runtime.
step_backup() {
    [ -f "$WORK/d3.qcow2" ] || { record d8 SKIP - "needs the appliance of d3"; return 1; }
    reset_extras
    with_disk data
    blank_disk backup 6G
    with_disk backup
    VM_CREDENTIALS+=("kamerplanter.backup-disk $(by_id backup)")
    start_vm d8 bios virtio-scsi virtio off "$WORK/d3.qcow2" || { record d8 FAIL - "qemu did not start"; return 1; }
    local secs status
    secs=$(boot_up d8 "$REBOOT_TIMEOUT") || return 1
    status=$(guest /usr/libexec/kamerplanter/disks status)
    echo "$status" >"$OUT/d8.status.txt"
    if grep -q '^backup disk: kp-backup, UUID .*, mounted at /var/mnt/kamerplanter-backup' <<<"$status" &&
        guest 'findmnt -rno OPTIONS -M /var/mnt/kamerplanter-backup | grep -q nosuid,nodev,noexec'; then
        record d8 PASS "${secs}s" "blank backup disk named by credential formatted and mounted next to the data disk"
    else
        fail d8 "backup disk not set up: ${status//$'\n'/; }"
    fi
    stop_vm
}

kill_vm 2>/dev/null
: >"$RESULTS"
steps=("$@")
[ ${#steps[@]} -gt 0 ] || steps=(build none move data replace missing downgrade luks backup)
for step in "${steps[@]}"; do
    # Only move continues on the VM a step before it left running.
    if [ "$step" != move ] && vm_alive; then stop_vm; fi
    "step_$step"
    rc=$?
    [ "$rc" = 0 ] && continue
    kill_vm 2>/dev/null
    # build and data are needed by every later step.
    if [ "$step" = build ] || [ "$step" = data ]; then break; fi
done
kill_vm 2>/dev/null
# The private key is left out so that it is never world-readable, not even
# briefly (see tests/boot/run.sh).
find "$OUT" "$WORK" ! -path "$KEY" -exec chmod a+rX {} +
chmod 600 "$KEY"
echo
column -t -s $'\t' "$RESULTS"
grep -q FAIL "$RESULTS" && exit 1
exit 0
