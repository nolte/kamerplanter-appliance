#!/usr/bin/env bash
# Checks the decisions of the disk service (image/rootfs/usr/libexec/kamerplanter/disks)
# and the naming check of the shared parser on fake input. Needs no root, no
# disk and no VM.
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

if [ "$failures" -gt 0 ]; then
    echo "$failures check(s) failed"
    exit 1
fi
echo "all checks passed"
