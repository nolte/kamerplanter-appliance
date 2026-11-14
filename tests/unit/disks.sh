#!/usr/bin/env bash
# Checks the decisions of the disk service (image/rootfs/usr/libexec/kamerplanter/disks)
# and the naming and placement checks, the release comparison and the release
# marker decisions of the shared parser (image/rootfs/usr/lib/kamerplanter/env.sh)
# on fake input and in temporary directories. Needs no root, no disk and no VM.
#
# Usage: tests/unit/disks.sh
set -uo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
# shellcheck source=image/rootfs/usr/lib/kamerplanter/env.sh
. "$root/image/rootfs/usr/lib/kamerplanter/env.sh"
# shellcheck source=image/rootfs/usr/libexec/kamerplanter/disks
. "$root/image/rootfs/usr/libexec/kamerplanter/disks"
set +e

failures=0
expect() {  # expect NAME EXPECTED ACTUAL
    if [ "$2" = "$3" ]; then
        printf 'ok    %s\n' "$1"
    else
        printf 'FAIL  %s\n      expected: %s\n      actual:   %s\n' "$1" "$2" "$3"
        failures=$((failures + 1))
    fi
}
accepts() { if disk_path_ok "$2"; then expect "$1" yes yes; else expect "$1" yes no; fi; }
rejects() { if disk_path_ok "$2"; then expect "$1" no yes; else expect "$1" no no; fi; }

# --- naming (E7) ---
accepts "by-id path" /dev/disk/by-id/usb-SanDisk_Cruzer_Blade_4C530001-0:0
accepts "by-id path of a partition" /dev/disk/by-id/ata-Samsung_SSD_860_EVO_500GB_S3Z1NB0K-part1
accepts "by-id virtio path" /dev/disk/by-id/virtio-kp-data
accepts "by-uuid path" /dev/disk/by-uuid/0d8b7c52-6f3e-4b1a-9a8e-3c1f2b4d5e6f
rejects "device name" /dev/sdb
rejects "by-label path" /dev/disk/by-label/kp-data
rejects "by-path path" /dev/disk/by-path/pci-0000:00:05.0
rejects "by-id directory itself" /dev/disk/by-id/
rejects "parent directory" /dev/disk/by-id/..
rejects "path traversal" /dev/disk/by-id/../../sda
rejects "trailing component" /dev/disk/by-id/usb-x/y
rejects "space" "/dev/disk/by-id/usb x"
rejects "newline" $'/dev/disk/by-id/usb-x\n/dev/sda'
rejects "relative path" dev/disk/by-id/usb-x
rejects "empty" ""

# --- finding a set-up disk by label under its UUID (E8, E12) ---
uuid=0d8b7c52-6f3e-4b1a-9a8e-3c1f2b4d5e6f
system=$'DEVNAME=/dev/vda3\nLABEL=root\nUUID=11111111-2222-3333-4444-555555555555\nBLOCK_SIZE=4096\nTYPE=ext4\n'
data=$'DEVNAME=/dev/vdb\nLABEL=kp-data\nUUID='$uuid$'\nBLOCK_SIZE=4096\nTYPE=ext4\n'
clone=$'DEVNAME=/dev/sdc\nLABEL=kp-data\nUUID=99999999-8888-7777-6666-555555555555\nTYPE=ext4\n'
partlabel=$'DEVNAME=/dev/sdd1\nPARTLABEL=kp-data\nPARTUUID=abcd\n'
backup=$'DEVNAME=/dev/sde\nLABEL=kp-backup\nUUID=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\nTYPE=ext4\n'

expect "set-up disk present" "ok /dev/vdb" "$(printf '%s\n%s' "$system" "$data" | classify kp-data "$uuid")"
expect "UUID compares case-blind" "ok /dev/vdb" "$(printf '%s\n%s' "$system" "$data" | classify kp-data "${uuid^^}")"
expect "last device without a blank line after it" "ok /dev/vdb" "$(printf '%s\n%s' "$system" "${data%$'\n'}" | classify kp-data "$uuid")"
expect "set-up disk missing" missing "$(printf '%s\n' "$system" | classify kp-data "$uuid")"
expect "no devices at all" missing "$(printf '' | classify kp-data "$uuid")"
expect "label only under another UUID" "foreign /dev/sdc 99999999-8888-7777-6666-555555555555" \
    "$(printf '%s\n%s' "$system" "$clone" | classify kp-data "$uuid")"
expect "label on two devices" "duplicate /dev/vdb /dev/sdc" \
    "$(printf '%s\n%s\n%s' "$system" "$data" "$clone" | classify kp-data "$uuid")"
expect "label on two devices, both under the recorded UUID" "duplicate /dev/vdb /dev/sdc" \
    "$(printf '%s\n%s\n%s' "$data" "$system" "${data/vdb/sdc}" | classify kp-data "$uuid")"
expect "partition name does not count as label" missing "$(printf '%s\n%s' "$system" "$partlabel" | classify kp-data "$uuid")"
expect "other role's label does not count" missing "$(printf '%s\n%s' "$system" "$backup" | classify kp-data "$uuid")"
expect "backup disk found by its own label" "ok /dev/sde" \
    "$(printf '%s\n%s\n%s' "$system" "$data" "$backup" | classify kp-backup aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee)"
expect "label without UUID" "foreign /dev/sdf none" "$(printf 'DEVNAME=/dev/sdf\nLABEL=kp-data\n' | classify kp-data "$uuid")"

# --- set-up of a named disk (E7, E10) ---
expect "blank disk is formatted" format "$(setup_action kp-data '' '' '' 0 0)"
expect "blank disk, forced, is formatted" format "$(setup_action kp-data '' '' '' 1 0)"
expect "own label on ext4 is adopted" adopt "$(setup_action kp-data ext4 kp-data 'it carries the label kp-data on ext4' 0 0 ext4)"
expect "own label on ext4 is adopted, also when forced" adopt "$(setup_action kp-data ext4 kp-data 'it carries the label kp-data on ext4' 1 0 ext4)"
expect "foreign file system is refused, naming it" \
    "refuse it carries xfs; it is formatted only when the naming forces it" \
    "$(setup_action kp-data xfs '' '' 0 0 xfs)"
expect "partition table is refused, naming every signature" \
    "refuse it carries gpt, PMBR, ntfs on /dev/sdb1; it is formatted only when the naming forces it" \
    "$(setup_action kp-data '' '' '' 0 0 gpt PMBR 'ntfs on /dev/sdb1')"
expect "foreign file system, forced, is wiped" wipe "$(setup_action kp-data xfs '' '' 1 0 xfs)"
expect "a force applies once to its path" \
    "refuse it carries vfat, and the forced format of this path was used already" \
    "$(setup_action kp-data vfat '' '' 1 1 vfat)"
expect "the other label is never formatted, even forced" \
    "refuse it carries the label kp-backup on ext4, and is never formatted again" \
    "$(setup_action kp-data ext4 kp-backup 'it carries the label kp-backup on ext4' 1 0 ext4)"
expect "own label on another file system is never formatted" \
    "refuse it carries the label kp-data on xfs, and is never formatted again" \
    "$(setup_action kp-data xfs kp-data 'it carries the label kp-data on xfs' 1 0 xfs)"
expect "a partition with the label is never formatted, even forced" \
    "refuse its partition /dev/sdb1 carries the label kp-data, and is never formatted again" \
    "$(setup_action kp-data '' '' 'its partition /dev/sdb1 carries the label kp-data' 1 0 gpt PMBR 'ext4 on /dev/sdb1')"
expect "backup disk adopts kp-backup" adopt "$(setup_action kp-backup ext4 kp-backup 'it carries the label kp-backup on ext4' 0 0 ext4)"

# --- local disks only (E15) ---
expect "virtio disk is local" "" "$(remote_kind vdb '' /sys/devices/pci0000:00/0000:00:05.0/virtio2/block/vdb)"
expect "USB disk is local" "" "$(remote_kind sdb usb /sys/devices/pci0000:00/0000:00:14.0/usb2/2-1/2-1:1.0/host6/target6:0:0/6:0:0:0/block/sdb)"
expect "NVMe disk is local" "" "$(remote_kind nvme0n1 nvme /sys/devices/pci0000:00/0000:00:1d.0/0000:3d:00.0/nvme/nvme0/nvme0n1)"
expect "SATA partition is local" "" "$(remote_kind sda1 '' /sys/devices/pci0000:00/0000:00:17.0/ata1/host0/target0:0:0/0:0:0:0/block/sda/sda1)"
expect "iSCSI by transport" "sdc is attached over the network (iscsi)" "$(remote_kind sdc iscsi /sys/devices/platform/host3/session1/target3:0:0/3:0:0:1/block/sdc)"
expect "iSCSI by session" "sdc is attached over the network" "$(remote_kind sdc '' /sys/devices/platform/host3/session1/target3:0:0/3:0:0:1/block/sdc)"
expect "NVMe over TCP" "nvme1n1 is attached over the network (tcp)" "$(remote_kind nvme1n1 tcp /sys/devices/virtual/nvme-fabrics/ctl/nvme1/nvme1n1)"
expect "NBD" "nbd0 is a network block device" "$(remote_kind nbd0 '' /sys/devices/virtual/block/nbd0)"
expect "Ceph RBD" "rbd0 is a network block device" "$(remote_kind rbd0 '' /sys/devices/virtual/block/rbd0)"
expect "loop device" "loop0 is not a disk" "$(remote_kind loop0 '' /sys/devices/virtual/block/loop0)"

# --- content of the data disk (E9, E10, E12) ---
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
problem() {  # problem NAME EXPECTED SETUP: layout_problem of a fresh tree after SETUP
    local d
    d=$(mktemp -d "$work/disk.XXXXXX")
    (cd "$d" && eval "$3")
    expect "$1" "$2" "$(layout_problem "$d")"
}
full='mkdir -p etc pinned volumes/arangodb_data/_data volumes/valkey_data/_data && touch etc/kamerplanter.env etc/secrets.env pinned/FERNET_KEY'
problem "blank disk: every location is created" "" ":"
problem "complete layout is used" "" "$full"
problem "layout with volumes not yet created by Podman" "" "mkdir -p etc pinned volumes/arangodb_data"
problem "lost+found and other entries at the top are ignored" "" "$full && mkdir lost+found && touch notes"
problem "etc as symbolic link" "etc is a symbolic link" "ln -s /etc etc"
problem "etc as file" "etc is not a directory" "touch etc"
problem "volumes as symbolic link" "volumes is a symbolic link" "mkdir -p etc pinned && ln -s / volumes"
problem "volume as symbolic link" "volumes/valkey_data is a symbolic link" "mkdir -p volumes/arangodb_data && ln -s /var volumes/valkey_data"
problem "_data as symbolic link" "volumes/arangodb_data/_data is a symbolic link" "mkdir -p volumes/arangodb_data && ln -s /etc volumes/arangodb_data/_data"
problem "_data as file" "volumes/arangodb_data/_data is not a directory" "mkdir -p volumes/arangodb_data && touch volumes/arangodb_data/_data"
problem "secrets as symbolic link" "etc/secrets.env is a symbolic link" "$full && rm etc/secrets.env && ln -s /etc/shadow etc/secrets.env"
problem "dangling symbolic link in pinned" "pinned/FERNET_KEY is a symbolic link" "$full && rm pinned/FERNET_KEY && ln -s /nowhere pinned/FERNET_KEY"
problem "secrets hard-linked into a volume" "etc/secrets.env has 2 hard links" "$full && ln etc/secrets.env volumes/arangodb_data/_data/s"
problem "pin hard-linked into the top of the disk" "pinned/FERNET_KEY has 2 hard links" "$full && ln pinned/FERNET_KEY copy"
problem "FIFO in etc" "etc/pipe is a device or other special file" "$full && mkfifo etc/pipe"
problem "directory in etc" "etc/sub is a directory" "$full && mkdir etc/sub"
problem "unprintable name is shown masked" "etc/a?b is a symbolic link" "$full && ln -s x etc/a\$'\\n'b"
problem "files in a volume are the database's own" "" "$full && ln -s / volumes/valkey_data/_data/link && mkfifo volumes/valkey_data/_data/fifo"

held() {  # held NAME EXPECTED SETUP: system_data of a fresh root after SETUP
    local d
    d=$(mktemp -d "$work/root.XXXXXX")
    (cd "$d" && eval "$3")
    expect "$1" "$2" "$(system_data "$d")"
}
vol=var/lib/containers/storage/volumes
held "fresh appliance holds nothing" "" ":"
held "the shipped user file does not count" "" "mkdir -p etc/kamerplanter && touch etc/kamerplanter/kamerplanter.env"
held "empty pins and bind targets do not count" "" "mkdir -p var/lib/kamerplanter/pinned $vol/arangodb_data $vol/valkey_data/_data"
held "secrets on the system disk" "/etc/kamerplanter/secrets.env" "mkdir -p etc/kamerplanter && touch etc/kamerplanter/secrets.env"
held "pins on the system disk" "pins in /var/lib/kamerplanter/pinned" "mkdir -p var/lib/kamerplanter/pinned && touch var/lib/kamerplanter/pinned/FERNET_KEY"
held "database data on the system disk" "data in /var/lib/containers/storage/volumes/arangodb_data" \
    "mkdir -p $vol/arangodb_data/_data && touch $vol/arangodb_data/_data/ENGINE"
held "everything listed" $'/etc/kamerplanter/secrets.env\npins in /var/lib/kamerplanter/pinned\ndata in /var/lib/containers/storage/volumes/valkey_data' \
    "mkdir -p etc/kamerplanter var/lib/kamerplanter/pinned $vol/valkey_data/_data && touch etc/kamerplanter/secrets.env var/lib/kamerplanter/pinned/X $vol/valkey_data/_data/dump.rdb"

# The maintenance window: reloaded only when the disk's user file changes it.
window_generator=$work/generator
window_conf=$work/run/kamerplanter-update-apply.timer.d/50-window.conf
mkdir -p "${window_conf%/*}"
printf '[Timer]\nOnCalendar=*-*-* 03:00:00\n' >"$window_conf"
gen() {  # gen WINDOW [COMMAND]: a generator that runs COMMAND, then writes WINDOW
    cat >"$window_generator" <<EOF
#!/usr/bin/bash
${2-}
mkdir -p "\$1/kamerplanter-update-apply.timer.d"
printf '[Timer]\\nOnCalendar=*-*-* $1:00\\n' >"\$1/kamerplanter-update-apply.timer.d/50-window.conf"
EOF
    chmod +x "$window_generator"
}
stale() { if window_stale; then echo stale; else echo current; fi; }
gen 03:00; expect "same window: no reload" current "$(stale)"
gen 05:17; expect "window from the disk differs: reload" stale "$(stale)"
gen 05:17 'exit 1'; expect "generator fails: no reload" current "$(stale)"
gen 05:17; rm "$window_conf"; expect "no drop-in written at boot: reload" stale "$(stale)"

# SELinux labels by the bound paths.
calls=$work/restorecon.calls
selinuxenabled() { return 0; }
restorecon() { echo "restorecon $*" >>"$calls"; }
mnt=/var/mnt/kamerplanter-data new_dirs=()
: >"$calls"; first_use=1; relabel
expect "new disk: volumes relabelled throughout" \
    "restorecon /var/mnt/kamerplanter-data|restorecon -R /etc/kamerplanter /var/lib/kamerplanter/pinned /var/lib/containers/storage/volumes/arangodb_data /var/lib/containers/storage/volumes/valkey_data" \
    "$(paste -sd'|' "$calls")"
: >"$calls"; first_use=0; new_dirs=(/var/lib/containers/storage/volumes/x /var/lib/containers); relabel
expect "known disk: volume directories only, plus new system directories" \
    "restorecon /var/mnt/kamerplanter-data /var/lib/containers/storage/volumes/arangodb_data /var/lib/containers/storage/volumes/valkey_data /var/lib/containers/storage/volumes/x /var/lib/containers|restorecon -R /etc/kamerplanter /var/lib/kamerplanter/pinned" \
    "$(paste -sd'|' "$calls")"
selinuxenabled() { return 1; }
: >"$calls"; first_use=1; new_dirs=(); relabel
expect "SELinux disabled: nothing relabelled" "" "$(cat "$calls")"
unset -f selinuxenabled restorecon

# The writers' check (configure, the update guard).
placed() { if data_disk_placed; then echo placed; else echo "not placed"; fi; }
data_disk_record=$work/none.env
expect "no data disk set up: the system disk is used" placed "$(placed)"
data_disk_record=$work/data.env data_disk_mount=$work/mnt
touch "$data_disk_record"; mkdir -p "$data_disk_mount"
expect "data disk set up, not mounted: nothing is written" "not placed" "$(placed)"

# --- release comparison and marker (spec/update-and-rollback/ A4, A7; E13) ---
yesno() { if "$@"; then echo yes; else echo no; fi; }
expect "forward: newer release follows" yes "$(yesno forward 1.3 1.2)"
expect "forward: patch release follows" yes "$(yesno forward 1.2.1 1.2)"
expect "forward: v prefix is the same release" no "$(yesno forward v1.2 1.2)"
expect "forward: same release does not follow" no "$(yesno forward 1.2 1.2)"
expect "forward: older release does not follow" no "$(yesno forward 1.10 1.11)"
expect "forward: numeric, not lexical order" yes "$(yesno forward 1.10 1.9)"
expect "forward: development build never follows a release" no "$(yesno forward dev 1.2)"
expect "forward: anything follows a development build" yes "$(yesno forward 0.1 dev)"

expect "no marker: no release refused" no "$(yesno marker_refuses '' 1.2)"
expect "no marker: development build runs" no "$(yesno marker_refuses '' dev)"
expect "marker of a newer release refuses" yes "$(yesno marker_refuses 1.3 1.2)"
expect "marker of a newer patch release refuses" yes "$(yesno marker_refuses 1.2.1 1.2)"
expect "marker of the same release does not refuse" no "$(yesno marker_refuses 1.2 1.2)"
expect "marker of the same release with v does not refuse" no "$(yesno marker_refuses 1.2 v1.2)"
expect "marker of an older release does not refuse" no "$(yesno marker_refuses 1.2 1.3)"
expect "development build refused on a disk of the oldest release" yes "$(yesno marker_refuses 0.1 dev)"
expect "unversioned build refused on a marked disk" yes "$(yesno marker_refuses 1.0 unversioned)"
expect "unreadable marker refuses a release" yes "$(yesno marker_refuses unreadable 9.9)"
expect "unreadable marker refuses a development build" yes "$(yesno marker_refuses unreadable dev)"

expect "release marks an unmarked disk" yes "$(yesno marker_raises 1.2 '')"
expect "newer release raises the marker" yes "$(yesno marker_raises 1.3 1.2)"
expect "same release leaves the marker" no "$(yesno marker_raises 1.2 1.2)"
expect "older release (allowed by override) never lowers the marker" no "$(yesno marker_raises 1.2 1.3)"
expect "release replaces an unreadable marker" yes "$(yesno marker_raises 1.2 unreadable)"
expect "development build never raises a release's marker" no "$(yesno marker_raises dev 0.1)"
expect "development build leaves an unmarked disk unmarked" no "$(yesno marker_raises dev '')"

overrides=$work/downgrades
printf '1.4 1.3 2026-11-14T10:00:00Z\nunreadable 1.2 2026-11-14T11:00:00Z\n1.4 dev 2026-11-14T12:00:00Z\n' >"$overrides"
expect "override holds for its pair" yes "$(yesno downgrade_allowed 1.4 1.3 "$overrides")"
expect "override not for another running release" no "$(yesno downgrade_allowed 1.4 1.2 "$overrides")"
expect "override not for another disk release" no "$(yesno downgrade_allowed 1.5 1.3 "$overrides")"
expect "override not for the reversed pair" no "$(yesno downgrade_allowed 1.3 1.4 "$overrides")"
expect "override no prefix match" no "$(yesno downgrade_allowed 1.4 1.3.1 "$overrides")"
expect "override of an unreadable marker" yes "$(yesno downgrade_allowed unreadable 1.2 "$overrides")"
expect "override for a development build" yes "$(yesno downgrade_allowed 1.4 dev "$overrides")"
expect "no overrides recorded" no "$(yesno downgrade_allowed 1.4 1.3 "$work/none")"

# Reading the marker: only from a set-up, mounted disk; only a release.
mountpoint() { [ "${!#}" = "$data_disk_mount" ] && [ -e "$data_disk_mount/.mounted" ]; }
data_disk_marker=$data_disk_mount/release
marker() { data_disk_release; echo "|$?"; }
data_disk_record=$work/none.env
expect "marker: no data disk set up" "|0" "$(marker)"
data_disk_record=$work/data.env
expect "marker: disk set up, not mounted" "|0" "$(marker)"
touch "$data_disk_mount/.mounted"
expect "marker: mounted disk without marker" "|0" "$(marker)"
printf '1.4\n' >"$data_disk_marker"
expect "marker: release" "1.4|0" "$(marker)"
printf 'v1.4.2' >"$data_disk_marker"
expect "marker: v prefix and no line break" "1.4.2|0" "$(marker)"
printf '1.4\nsomething else\n' >"$data_disk_marker"
expect "marker: first line only" "1.4|0" "$(marker)"
printf 'dev\n' >"$data_disk_marker"
expect "marker: no release is unreadable" "unreadable|0" "$(marker)"
: >"$data_disk_marker"
expect "marker: empty is unreadable" "unreadable|0" "$(marker)"
head -c 200 /dev/zero | tr '\0' 1 >"$data_disk_marker"
expect "marker: overlong is unreadable" "unreadable|0" "$(marker)"
rm "$data_disk_marker"; printf '1.4\n' >"$work/elsewhere"; ln -s "$work/elsewhere" "$data_disk_marker"
expect "marker: symbolic link is unreadable" "unreadable|0" "$(marker)"
rm "$data_disk_marker"; ln -s "$work/nowhere" "$data_disk_marker"
expect "marker: dangling symbolic link is unreadable" "unreadable|0" "$(marker)"
rm "$data_disk_marker"; mkdir "$data_disk_marker"
expect "marker: directory is unreadable" "unreadable|0" "$(marker)"
unset -f mountpoint

if [ "$failures" -gt 0 ]; then
    echo "$failures check(s) failed"
    exit 1
fi
echo "all checks passed"
