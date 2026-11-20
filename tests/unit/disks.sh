#!/usr/bin/env bash
# Checks the decisions of the disk service (image/rootfs/usr/libexec/kamerplanter/disks),
# its key checks (E14), the decisions and the record of a move onto a data disk (E11),
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
expect "blank disk is formatted" format "$(setup_action kp-data '' '' '' 0 0 0)"
expect "blank disk, forced, is formatted" format "$(setup_action kp-data '' '' '' 1 0 0)"
expect "own label on ext4 is adopted" adopt "$(setup_action kp-data ext4 kp-data 'it carries the label kp-data on ext4' 0 0 0 ext4)"
expect "own label on ext4 is adopted, also when forced" adopt "$(setup_action kp-data ext4 kp-data 'it carries the label kp-data on ext4' 1 0 0 ext4)"
expect "foreign file system is refused, naming it" \
    "refuse it carries xfs; it is formatted only when the naming forces it" \
    "$(setup_action kp-data xfs '' '' 0 0 0 xfs)"
expect "partition table is refused, naming every signature" \
    "refuse it carries gpt, PMBR, ntfs on /dev/sdb1; it is formatted only when the naming forces it" \
    "$(setup_action kp-data '' '' '' 0 0 0 gpt PMBR 'ntfs on /dev/sdb1')"
expect "foreign file system, forced, is wiped" wipe "$(setup_action kp-data xfs '' '' 1 0 0 xfs)"
expect "a force applies once to its path" \
    "refuse it carries vfat, and the forced format of this device was used already" \
    "$(setup_action kp-data vfat '' '' 1 1 0 vfat)"
expect "the other label is never formatted, even forced" \
    "refuse it carries the label kp-backup on ext4, and is never formatted again" \
    "$(setup_action kp-data ext4 kp-backup 'it carries the label kp-backup on ext4' 1 0 0 ext4)"
expect "own label on another file system is never formatted" \
    "refuse it carries the label kp-data on xfs, and is never formatted again" \
    "$(setup_action kp-data xfs kp-data 'it carries the label kp-data on xfs' 1 0 0 xfs)"
expect "a partition with the label is never formatted, even forced" \
    "refuse its partition /dev/sdb1 carries the label kp-data, and is never formatted again" \
    "$(setup_action kp-data '' '' 'its partition /dev/sdb1 carries the label kp-data' 1 0 0 gpt PMBR 'ext4 on /dev/sdb1')"
expect "backup disk adopts kp-backup" adopt "$(setup_action kp-backup ext4 kp-backup 'it carries the label kp-backup on ext4' 0 0 0 ext4)"

# --- encryption (E14, E16) ---
luks=$'DEVNAME=/dev/sdb\nVERSION=2\nUUID=dd9c4f97-77b2-4ef6-8266-7607ede0420e\nLABEL=kp-data\nTYPE=crypto_LUKS\nUSAGE=crypto\n'
inner=$'DEVNAME=/dev/mapper/kamerplanter-data\nLABEL=kp-data\nUUID=4d0441f2-c494-4652-b5ca-7ac746f1efcb\nBLOCK_SIZE=4096\nTYPE=ext4\n'
luks_id=dd9c4f97-77b2-4ef6-8266-7607ede0420e
expect "encrypted disk found by its header label" "ok /dev/sdb" "$(printf '%s\n%s' "$system" "$luks" | classify kp-data "$luks_id")"
expect "opened container skipped: header label counts once" "ok /dev/sdb" \
    "$(printf '%s\n%s\n%s' "$system" "$luks" "$inner" | classify kp-data "$luks_id" /dev/mapper/kamerplanter-data /dev/dm-0)"
expect "opened container skipped by its kernel name too" "ok /dev/sdb" \
    "$(printf '%s\n%s\n%s' "$system" "$luks" "${inner/mapper\/kamerplanter-data/dm-0}" | classify kp-data "$luks_id" /dev/mapper/kamerplanter-data /dev/dm-0)"
expect "opened container not skipped: duplicate" "duplicate /dev/sdb /dev/mapper/kamerplanter-data" \
    "$(printf '%s\n%s\n%s' "$system" "$luks" "$inner" | classify kp-data "$luks_id")"
expect "skipping the container does not hide an unencrypted clone" "duplicate /dev/sdb /dev/sdc" \
    "$(printf '%s\n%s\n%s\n%s' "$system" "$luks" "$inner" "$clone" | classify kp-data "$luks_id" /dev/mapper/kamerplanter-data)"
expect "set up encrypted, only an unencrypted disk present" "foreign /dev/sdc 99999999-8888-7777-6666-555555555555" \
    "$(printf '%s\n%s' "$system" "$clone" | classify kp-data "$luks_id" /dev/mapper/kamerplanter-data)"
expect "skip list matches whole device names only" "duplicate /dev/sdb /dev/mapper/kamerplanter-data" \
    "$(printf '%s\n%s\n%s' "$system" "$luks" "$inner" | classify kp-data "$luks_id" /dev/mapper/kamerplanter)"

expect "blank disk with a key is formatted (encrypted)" format "$(setup_action kp-data '' '' '' 0 0 1)"
expect "foreign file system with a key, forced, is wiped (then encrypted)" wipe "$(setup_action kp-data xfs '' '' 1 0 1 xfs)"
expect "foreign file system with a key, not forced, is refused" \
    "refuse it carries xfs; it is formatted only when the naming forces it" "$(setup_action kp-data xfs '' '' 0 0 1 xfs)"
expect "a key for a disk set up unencrypted is refused" \
    "refuse it carries kp-data unencrypted, and a key is supplied for it: a disk is encrypted only when it is formatted" \
    "$(setup_action kp-data ext4 kp-data 'it carries the label kp-data on ext4' 0 0 1 ext4)"
expect "a key for a disk set up unencrypted is refused, also when forced" \
    "refuse it carries kp-data unencrypted, and a key is supplied for it: a disk is encrypted only when it is formatted" \
    "$(setup_action kp-data ext4 kp-data 'it carries the label kp-data on ext4' 1 0 1 ext4)"
expect "encrypted disk with a key is unlocked and adopted" unlock \
    "$(setup_action kp-data crypto_LUKS kp-data 'it carries the label kp-data on crypto_LUKS' 0 0 1 crypto_LUKS)"
expect "encrypted disk without a key is refused" \
    "refuse it carries kp-data encrypted (LUKS), and no key is supplied for it" \
    "$(setup_action kp-data crypto_LUKS kp-data 'it carries the label kp-data on crypto_LUKS' 1 0 0 crypto_LUKS)"
expect "encrypted disk of the other role is never formatted" \
    "refuse it carries the label kp-backup on crypto_LUKS, and is never formatted again" \
    "$(setup_action kp-data crypto_LUKS kp-backup 'it carries the label kp-backup on crypto_LUKS' 1 0 1 crypto_LUKS)"
expect "unlabelled LUKS container is foreign" \
    "refuse it carries crypto_LUKS; it is formatted only when the naming forces it" \
    "$(setup_action kp-data crypto_LUKS '' '' 0 0 1 crypto_LUKS)"

expect "key of 31 bytes refused" "it is shorter than 32 bytes" "$(key_size_problem 31)"
expect "key of 32 bytes accepted" "" "$(key_size_problem 32)"
expect "key of 8192 bytes accepted" "" "$(key_size_problem 8192)"
expect "key of 8193 bytes refused" "it is longer than 8192 bytes" "$(key_size_problem 8193)"
expect "empty key refused" "it is shorter than 32 bytes" "$(key_size_problem 0)"

expect "LUKS2 UUID from the mapping" dd9c4f97-77b2-4ef6-8266-7607ede0420e \
    "$(luks_uuid CRYPT-LUKS2-dd9c4f9777b24ef682667607ede0420e-kamerplanter-data)"
expect "LUKS2 UUID compares lower-case" dd9c4f97-77b2-4ef6-8266-7607ede0420e \
    "$(luks_uuid CRYPT-LUKS2-DD9C4F9777B24EF682667607EDE0420E-kamerplanter-data)"
expect "LUKS1 mapping is no LUKS2 container" "" "$(luks_uuid CRYPT-LUKS1-dd9c4f9777b24ef682667607ede0420e-x)"
expect "plain dm-crypt mapping is none" "" "$(luks_uuid CRYPT-PLAIN-kamerplanter-data)"
expect "LVM mapping is none" "" "$(luks_uuid LVM-abcdef)"
expect "no mapping is none" "" "$(luks_uuid '')"

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
problem "keyed pins and their key are used" "" "$full && touch pinned/.key pinned/FERNET_KEY.hmac"
problem "the key of the pins hard-linked elsewhere" "pinned/.key has 2 hard links" "$full && touch pinned/.key && ln pinned/.key copy"
problem "FIFO in etc" "etc/pipe is a device or other special file" "$full && mkfifo etc/pipe"
problem "directory in etc" "etc/sub is a directory" "$full && mkdir etc/sub"
problem "unprintable name is shown masked" "etc/a?b is a symbolic link" "$full && ln -s x etc/a\$'\\n'b"
problem "files in a volume are the database's own" "" "$full && ln -s / volumes/valkey_data/_data/link && mkfifo volumes/valkey_data/_data/fifo"
# The top of the disk, where the update tool writes and deletes as root (W1).
D=sha256:$(printf '%064d' 1)
victim=$(mktemp -d "$work/victim.XXXXXX")
problem "backups and the marker at the top are used" "" "$full && mkdir -p update-backup/$D && echo 1.0 >release"
problem "update-backup as symbolic link" "update-backup is a symbolic link" "$full && ln -s $victim update-backup"
problem "a backup as symbolic link" "update-backup/$D is a symbolic link" "$full && mkdir update-backup && ln -s $victim update-backup/$D"
problem "any entry as symbolic link" "update-backup/x is a symbolic link" "$full && mkdir update-backup && ln -s $victim update-backup/x"
problem "update-backup as file" "update-backup is not a directory" "$full && touch update-backup"
problem "a file in update-backup" "update-backup/f is not a directory" "$full && mkdir update-backup && touch update-backup/f"
problem "release marker as symbolic link" "release is a symbolic link" "$full && ln -s $victim/m release"
problem "release marker as directory" "release is not a regular file" "$full && mkdir release"
b=$(mktemp -d "$work/backup.XXXXXX")
expect "backup disk: an empty top is fine" "" "$(top_problem "$b")"
mkdir "$b/update-backup"; ln -s "$victim" "$b/update-backup/$D"
expect "backup disk: a backup as symbolic link is refused" "update-backup/$D is a symbolic link" "$(top_problem "$b")"
rm -r "$b/update-backup"; ln -s "$victim" "$b/update-backup"
expect "backup disk: update-backup as symbolic link is refused" "update-backup is a symbolic link" "$(top_problem "$b")"
expect "the victim is untouched by the checks" "" "$(ls -A "$victim")"

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
held "the key of the pins counts like a pin, so a data disk receives it with them" "pins in /var/lib/kamerplanter/pinned" \
    "mkdir -p var/lib/kamerplanter/pinned && touch var/lib/kamerplanter/pinned/.key"
held "database data on the system disk" "data in /var/lib/containers/storage/volumes/arangodb_data" \
    "mkdir -p $vol/arangodb_data/_data && touch $vol/arangodb_data/_data/ENGINE"
held "everything listed" $'/etc/kamerplanter/secrets.env\npins in /var/lib/kamerplanter/pinned\ndata in /var/lib/containers/storage/volumes/valkey_data' \
    "mkdir -p etc/kamerplanter var/lib/kamerplanter/pinned $vol/valkey_data/_data && touch etc/kamerplanter/secrets.env var/lib/kamerplanter/pinned/X $vol/valkey_data/_data/dump.rdb"

# Key files (E14): metadata only; owned by root and readable by root only.
keydir=$(mktemp -d "$work/keys.XXXXXX")
head -c 48 /dev/zero >"$keydir/ok"; chmod 0600 "$keydir/ok"
if [ "$(id -u)" = 0 ]; then
    expect "key file of root, 0600" "" "$(key_file_problem "$keydir/ok")"
    chmod 0400 "$keydir/ok"
    expect "key file of root, 0400 (a credential)" "" "$(key_file_problem "$keydir/ok")"
    chmod 0640 "$keydir/ok"
    expect "key file readable by its group" "its mode 640 lets others than root read it" "$(key_file_problem "$keydir/ok")"
else
    expect "key file not owned by root" "it is not owned by root" "$(key_file_problem "$keydir/ok")"
fi
ln -s "$keydir/ok" "$keydir/link"
expect "key file as symbolic link" "it is not a regular file" "$(key_file_problem "$keydir/link")"
mkdir "$keydir/dir"
expect "key file as directory" "it is not a regular file" "$(key_file_problem "$keydir/dir")"
expect "key file missing" "it is not a regular file" "$(key_file_problem "$keydir/none")"
printf 'LABEL=kp-data\nTYPE=ext4\nUUID=x\nENCRYPTION=luks2\n' >"$keydir/enc.env"
printf 'LABEL=kp-data\nTYPE=ext4\nUUID=x\nENCRYPTION=none\n' >"$keydir/plain.env"
printf 'LABEL=kp-data\nTYPE=ext4\nUUID=x\n' >"$keydir/p3.env"
yesno_enc() { if encrypted "$1"; then echo yes; else echo no; fi; }
expect "record of an encrypted disk" yes "$(yesno_enc "$keydir/enc.env")"
expect "record of an unencrypted disk" no "$(yesno_enc "$keydir/plain.env")"
expect "record written before encryption existed" no "$(yesno_enc "$keydir/p3.env")"
expect "no record" no "$(yesno_enc "$keydir/none.env")"

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

# --- naming only from the system side (W2) ---
nrec=$(mktemp -d "$work/naming.XXXXXX")
cred_dir=$nrec/creds
mkdir -p "$cred_dir"
names() {  # names: name|force|other_name|conflict, and what naming says
    (
        records=$nrec naming_file=$nrec/naming.env user=$nrec/user.env CREDENTIALS_DIRECTORY=$cred_dir
        owner_problem() { :; }
        mountpoint() { return 1; }
        die() { echo "DIE: $1"; exit 1; }
        role_vars "${1:-data}"
        naming 2>"$nrec/err"
        printf '%s|%s|%s|%s' "$name" "$force" "$other_name" "$conflict"
        if [ -s "$nrec/err" ]; then printf ' [%s]' "$(cat "$nrec/err")"; fi
    )
}
A=/dev/disk/by-id/virtio-a B=/dev/disk/by-id/virtio-b C=/dev/disk/by-id/virtio-c
printf 'DATA_DISK=%s\nDATA_DISK_FORCE=1\nBACKUP_DISK=%s\n' "$A" "$B" >"$nrec/user.env"
expect "naming: no data disk: the user file lies on the system disk and names disks" "$A|1|$B|" "$(names)"
touch "$nrec/data.env"
expect "naming: data disk set up: the user file is ignored, and that is said" \
    "|0|| [$nrec/user.env sets DATA_DISK DATA_DISK_FORCE, which is ignored there: that file lies on the data disk; name the data disk with: /usr/libexec/kamerplanter/disks name data PATH [force] (in $nrec/naming.env), or as the credential kamerplanter.data-disk]" \
    "$(names)"
expect "naming: data disk set up: BACKUP_DISK of the user file is ignored" "|0|| [$nrec/user.env sets BACKUP_DISK, which is ignored there: that file lies on the data disk; name the backup disk with: /usr/libexec/kamerplanter/disks name backup PATH [force] (in $nrec/naming.env), or as the credential kamerplanter.backup-disk]" \
    "$(names backup)"
printf 'DATA_DISK=\nDATA_DISK_FORCE=0\n' >"$nrec/user.env"
expect "naming: empty settings in the user file are nothing to ignore" "|0||" "$(names)"
printf 'DATA_DISK=%s\nBACKUP_DISK=%s\nBACKUP_DISK_FORCE=1\n' "$C" "$B" >"$nrec/naming.env"
expect "naming: the naming file on the system disk names disks" "$C|0|$B|" "$(names)"
expect "naming: and forces a format" "$B|1|$C|" "$(names backup)"
printf '%s\n' "$A" >"$cred_dir/kamerplanter.data-disk"
expect "naming: credential and naming file differ: a conflict" \
    "$A|0|$B|the credential kamerplanter.data-disk=$A and DATA_DISK in $nrec/naming.env=$C name different disks" "$(names)"
printf 'DATA_DISK=%s\n' "$A" >"$nrec/naming.env"
expect "naming: credential and naming file agree" "$A|0||" "$(names)"
rm "$nrec/data.env"; printf 'DATA_DISK=%s\n' "$B" >"$nrec/user.env"
expect "naming: no data disk: a differing user file is a conflict as before" \
    "$A|0||the credential kamerplanter.data-disk=$A and the setting DATA_DISK=$B name different disks" "$(names)"
rm "$cred_dir/kamerplanter.data-disk"
printf 'DATA_DISK=%s\n' "$(printf '/dev/disk/by-id/x\033[2J')" >"$nrec/naming.env"
expect "naming: a conflict is shown without control characters" \
    "DATA_DISK in $nrec/naming.env=/dev/disk/by-id/x?[2J and the setting DATA_DISK=$B name different disks" "$(names | cut -d'|' -f4)"
rm "$nrec/naming.env" "$nrec/user.env"
expect "naming: nothing named" "|0||" "$(names)"

naming_owner=$(mktemp "$work/naming.XXXXXX")
expect "naming file: missing is fine" "" "$(owner_problem "$work/none" "the naming file")"
if [ "$(id -u)" = 0 ]; then
    chmod 0600 "$naming_owner"
    expect "naming file: root, 0600" "" "$(owner_problem "$naming_owner" "the naming file")"
    chmod 0664 "$naming_owner"
    expect "naming file: writable by its group" "the naming file $naming_owner has the mode 664, which lets others than root change it" "$(owner_problem "$naming_owner" "the naming file")"
else
    expect "naming file: not owned by root" "the naming file $naming_owner is not owned by root" "$(owner_problem "$naming_owner" "the naming file")"
fi
ln -s "$naming_owner" "$work/naming.link"
expect "naming file: a link is refused" "the naming file $work/naming.link is not a regular file" "$(owner_problem "$work/naming.link" "the naming file")"

# --- a force is used once per device, not per path (S7) ---
expect "identity: the WWN" "wwn:0x5000c500a1b2c3d4" "$(device_identity 0x5000c500a1b2c3d4 S3Z1NB0K '' 8:16)"
expect "identity: the serial without a WWN" "serial:kpdata" "$(device_identity '' kpdata '' 252:16)"
expect "identity: a partition by its number" "serial:S3Z1NB0K:part2" "$(device_identity '' S3Z1NB0K 2 8:18)"
expect "identity: the device number without either" "devno:7:3" "$(device_identity '' '' '' 7:3)"
expect "identity: unprintable characters replaced" "serial:a?b" "$(device_identity '' $'a\nb' '' 8:0)"

# --- the disk selected is checked again, locked, before it is wiped or formatted ---
expect "same disk: nothing changed" "" "$(identity_problem /dev/sdb 8:16 serial:A /dev/sdb 8:16 serial:A)"
expect "same disk: the naming leads elsewhere" "it leads to /dev/sdc now, not to /dev/sdb" \
    "$(identity_problem /dev/sdb 8:16 serial:A /dev/sdc 8:32 serial:B)"
expect "same disk: the naming leads nowhere" "it leads to no device now, not to /dev/sdb" \
    "$(identity_problem /dev/sdb 8:16 serial:A '' '' '')"
expect "same disk: renumbered" "/dev/sdb has the device number 8:32 now, not 8:16" \
    "$(identity_problem /dev/sdb 8:16 serial:A /dev/sdb 8:32 serial:A)"
expect "same disk: gone" "/dev/sdb has the device number none now, not 8:16" \
    "$(identity_problem /dev/sdb 8:16 serial:A /dev/sdb '' devno:)"
expect "same disk: another disk under the same name and number" "/dev/sdb is serial:B now, not serial:A" \
    "$(identity_problem /dev/sdb 8:16 serial:A /dev/sdb 8:16 serial:B)"
expect "same disk: a partition of another disk" "/dev/sdb1 is wwn:0x2:part1 now, not wwn:0x1:part1" \
    "$(identity_problem /dev/sdb1 8:17 wwn:0x1:part1 /dev/sdb1 8:17 wwn:0x2:part1)"
same_disk_with() {  # same_disk_with NOW_DEV NOW_DEVNO NOW_IDENT NOW_NODE [named]: same_disk on /dev/sdb 8:16 serial:A node 5:100, with the naming, lsblk, sysfs and the node faked
    (
        name=/dev/disk/by-id/usb-a now_dev=$1 now_devno=$2 now_ident=$3 now_node=$4
        unset disk_lock
        readlink() { printf '%s\n' "$now_dev"; }
        lsblk_field() { printf '%s' "$now_devno"; }
        identity_of() { printf '%s' "$now_ident"; }
        device_node() { printf '%s' "$now_node"; }
        die() { echo "die: $1"; exit 1; }
        same_disk /dev/sdb 8:16 serial:A 5:100 "${5-}"
        echo written
    )
}
expect "same disk: the write goes ahead" written "$(same_disk_with /dev/sdb 8:16 serial:A 5:100)"
expect "same disk: another disk stops the start before the write" \
    "die: /dev/disk/by-id/usb-a (/dev/sdb) is not formatted, as it is no longer the disk selected: /dev/sdb is serial:B now, not serial:A; nothing is written to it" \
    "$(same_disk_with /dev/sdb 8:16 serial:B 5:100)"
expect "same disk: a disk without serial replaced under the same number stops the start" \
    "die: /dev/disk/by-id/usb-a (/dev/sdb) is not formatted, as it is no longer the disk selected: /dev/sdb is another device node now: a disk replaced it; nothing is written to it" \
    "$(same_disk_with /dev/sdb 8:16 serial:A 5:200)"
expect "same disk: a naming that leads elsewhere stops the start before the write" \
    "die: /dev/disk/by-id/usb-a (/dev/sdb) is not formatted, as it is no longer the disk selected: it leads to /dev/sdc now, not to /dev/sdb; nothing is written to it" \
    "$(same_disk_with /dev/sdc 8:16 serial:A 5:100 named)"
expect "same disk: after the first write the naming is not looked at again" written "$(same_disk_with /dev/sdc 8:16 serial:A 5:100)"
expect "same disk: nothing recorded to compare with stops the start" \
    "die: /dev/disk/by-id/usb-a (/dev/sdb) cannot be identified: it had no device number or node when it was selected; nothing is written to it" \
    "$(
        (
            name=/dev/disk/by-id/usb-a
            unset disk_lock
            die() { echo "die: $1"; exit 1; }
            same_disk /dev/sdb 8:16 serial:A ''
            echo written
        )
    )"
expect "same disk: the locked whole disk replaced stops the start" \
    "die: /dev/disk/by-id/usb-a (/dev/sdb1) is not formatted, as it is no longer the disk selected: /dev/sdb, which is locked, is another device node now: a disk replaced it; nothing is written to it" \
    "$(
        (
            name=/dev/disk/by-id/usb-a disk_lock=9 disk_lock_whole=/dev/sdb disk_lock_node=5:100
            lsblk_field() { printf 8:17; }
            identity_of() { printf serial:A:part1; }
            device_node() { if [ "$1" = /dev/sdb ]; then printf 5:200; else printf 5:101; fi; }
            die() { echo "die: $1"; exit 1; }
            same_disk /dev/sdb1 8:17 serial:A:part1 5:101
            echo written
        )
    )"
lockee=$work/disk.img
: >"$lockee"
locked_by_other() { if flock -n -x "$lockee" true; then echo free; else echo locked; fi; }
expect "lock: taken on the device, released by unlock_disk" "locked|free" "$(
    (
        lsblk_field() { :; }
        die() { echo "die: $1"; exit 1; }
        lock_disk "$lockee"
        printf '%s|' "$(locked_by_other)"
        unlock_disk
        locked_by_other
    )
)"
expect "lock: held by another program, the start stops without writing" \
    "die: $lockee, holding /dev/disk/by-id/usb-a, is locked by another program; it is not formatted" "$(
    (
        exec 8<"$lockee"
        flock -x 8
        name=/dev/disk/by-id/usb-a wait_seconds=0
        lsblk_field() { :; }
        die() { echo "die: $1"; exit 1; }
        lock_disk "$lockee"
        echo written
    )
)"

expect "lock: a partition whose disk cannot be found stops the start" \
    "die: /dev/sdb1, holding /dev/disk/by-id/usb-a, is a partition whose disk cannot be found to lock it; it is not formatted" "$(
    (
        name=/dev/disk/by-id/usb-a
        lsblk_field() { if [ "$2" = TYPE ]; then printf part; fi; }
        kname() { printf sdb1; }
        die() { echo "die: $1"; exit 1; }
        lock_disk /dev/sdb1
        echo written
    )
)"

# --- no key on the kernel command line (W5) ---
cmd=$work/cmdline
on_cmdline() { printf '%s\n' "$1" >"$cmd"; if cmdline_key "$cmd" "$2"; then echo refused; else echo fine; fi; }
expect "cmdline: a key credential for the data disk" refused "$(on_cmdline 'BOOT_IMAGE=/vmlinuz ro systemd.set_credential=kamerplanter.data-disk-key:secret quiet' data)"
expect "cmdline: a binary key credential" refused "$(on_cmdline 'ro systemd.set_credential_binary=kamerplanter.backup-disk-key:c2VjcmV0' backup)"
expect "cmdline: at the start, quoted" refused "$(on_cmdline '"systemd.set_credential=kamerplanter.data-disk-key:a b"' data)"
expect "cmdline: for the initrd" refused "$(on_cmdline 'rd.systemd.set_credential=kamerplanter.data-disk-key:x' data)"
expect "cmdline: the other disk's key does not count" fine "$(on_cmdline 'systemd.set_credential=kamerplanter.backup-disk-key:x' data)"
expect "cmdline: the disk naming may come this way" fine "$(on_cmdline 'systemd.set_credential=kamerplanter.data-disk:/dev/disk/by-id/x' data)"
expect "cmdline: a similar parameter" fine "$(on_cmdline 'xsystemd.set_credential=kamerplanter.data-disk-key:x' data)"
expect "cmdline: dashes for underscores in the parameter" refused "$(on_cmdline 'ro systemd.set-credential=kamerplanter.data-disk-key:x' data)"
expect "cmdline: binary with a dash" refused "$(on_cmdline 'systemd.set-credential-binary=kamerplanter.data-disk-key:eA==' data)"
expect "cmdline: binary mixed" refused "$(on_cmdline 'systemd.set_credential-binary=kamerplanter.data-disk-key:eA==' data)"
expect "cmdline: initrd with dashes" refused "$(on_cmdline 'rd.systemd.set-credential=kamerplanter.data-disk-key:x' data)"
expect "cmdline: quoted value" refused "$(on_cmdline 'systemd.set_credential="kamerplanter.data-disk-key:a b" quiet' data)"
expect "cmdline: quotes inside the credential name" refused "$(on_cmdline 'systemd.set_credential=kamerplanter."data"-disk-key:x' data)"
expect "cmdline: quotes inside the parameter name" refused "$(on_cmdline 'sys"temd".set_credential=kamerplanter.data-disk-key:x' data)"
expect "cmdline: tab before it" refused "$(on_cmdline $'ro\tsystemd.set_credential=kamerplanter.data-disk-key:x' data)"
expect "cmdline: dash and underscore are not the same in the credential name" fine "$(on_cmdline 'systemd.set_credential=kamerplanter.data_disk_key:x' data)"
expect "cmdline: an unrelated credential" fine "$(on_cmdline 'systemd.set-credential=io.systemd.firstboot.locale:de_DE systemd.set_credential=kamerplanter.data-disk-keyring:x' data)"
expect "cmdline: the name inside a quoted value of another parameter" fine "$(on_cmdline 'foo="systemd.set_credential=kamerplanter.data-disk-key:x"' data)"
expect "cmdline: no command line" fine "$(if cmdline_key "$work/none" data; then echo refused; else echo fine; fi)"

# --- the data of an opened container must be encrypted as set up ---
status_ok=$'/dev/mapper/kamerplanter-data is active.\n  type:    LUKS2\n  cipher:  aes-xts-plain64\n  keysize: 512 [bits]\n  key location: keyring\n  device:  /dev/vdb'
expect "cipher: as set up" "" "$(cipher_problem "$status_ok" aes-xts-plain64 512)"
expect "cipher: older cryptsetup says bits without brackets" "" "$(cipher_problem "${status_ok/512 \[bits\]/512 bits}" aes-xts-plain64 512)"
expect "cipher: cipher_null is refused" "its data is not encrypted (cipher_null)" \
    "$(cipher_problem "${status_ok/aes-xts-plain64/cipher_null-ecb}" aes-xts-plain64 512)"
expect "cipher: another cipher" "its data is encrypted with aes-cbc-essiv:sha256 and a key of 512 bits, not with aes-xts-plain64 and 512 bits as it was set up" \
    "$(cipher_problem "${status_ok/aes-xts-plain64/aes-cbc-essiv:sha256}" aes-xts-plain64 512)"
expect "cipher: a shorter key" "its data is encrypted with aes-xts-plain64 and a key of 256 bits, not with aes-xts-plain64 and 512 bits as it was set up" \
    "$(cipher_problem "${status_ok/512/256}" aes-xts-plain64 512)"
expect "cipher: nothing known about it" "its data is encrypted with an unknown cipher and a key of unknown bits, not with aes-xts-plain64 and 512 bits as it was set up" \
    "$(cipher_problem "/dev/mapper/kamerplanter-data is inactive." aes-xts-plain64 512)"
expect "cipher: the set-up uses what is checked" "aes-xts-plain64 512" "$luks_cipher $luks_key_bits"

# --- the system disk's copy is deleted only in a namespace of its own (S6) ---
out=$( (cmd_clean_underneath) 2>&1 ); rc=$?
expect "clean-underneath: refused in the system's mount namespace" "1|clean-underneath runs only in a mount namespace of its own (disks cleanup)" "$rc|$out"

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

# --- moving the system disk's data onto a data disk (E11) ---
tr_() { local n; n=$(move_transition "$1" "$2"); echo "${n:-refused}"; }
expect "move: begins without a record" copying "$(tr_ none start)"
expect "move: an interrupted copy starts over" copying "$(tr_ copying start)"
expect "move: a failed move starts again once named anew" copying "$(tr_ failed start)"
expect "move: complete copy is moved" moved "$(tr_ copying copied)"
expect "move: a copy that cannot be made is abandoned" failed "$(tr_ copying abandon)"
expect "move: healthy from the disk" verified "$(tr_ moved healthy)"
expect "move: unhealthy from the disk falls back" falling-back "$(tr_ moved unhealthy)"
expect "move: back on the system copy" failed "$(tr_ falling-back returned)"
expect "move: system copy deleted after verification" cleaned "$(tr_ verified cleaned)"
expect "move: no deletion before the health check" refused "$(tr_ moved cleaned)"
expect "move: no deletion while copying" refused "$(tr_ copying cleaned)"
expect "move: no deletion after a fallback" refused "$(tr_ failed cleaned)"
expect "move: no new move over a disk in use" refused "$(tr_ moved start)"
expect "move: no new move over a verified one" refused "$(tr_ verified start)"
expect "move: no new move over a cleaned one" refused "$(tr_ cleaned start)"
expect "move: no health result while copying" refused "$(tr_ copying healthy)"
expect "move: no fallback once verified" refused "$(tr_ verified unhealthy)"
expect "move: no fallback once cleaned" refused "$(tr_ cleaned unhealthy)"
expect "move: nothing returns without a fallback" refused "$(tr_ moved returned)"
expect "move: unknown state" refused "$(tr_ bogus start)"

expect "move target: blank file system" ok "$(move_target '' "$uuid" '')"
expect "move target: own earlier target with content" ok "$(move_target $'etc\nvolumes' "$uuid" "$uuid")"
expect "move target: own earlier target, UUID case-blind" ok "$(move_target 'etc' "${uuid^^}" "$uuid")"
expect "move target: foreign data refused, entries named" "refuse it holds data of its own (etc, release, volumes)" \
    "$(move_target $'etc\nrelease\nvolumes' "$uuid" '')"
expect "move target: another disk's earlier move does not count" "refuse it holds data of its own (notes)" \
    "$(move_target notes "$uuid" 99999999-8888-7777-6666-555555555555)"
expect "move target: any earlier target counts" ok "$(move_target etc "$uuid" $'99999999-8888-7777-6666-555555555555\n'"$uuid")"
expect "move target: no prefix match" "refuse it holds data of its own (etc)" "$(move_target etc "${uuid:0:8}" "$uuid")"
expect "move target: no identity, no match" "refuse it holds data of its own (etc)" "$(move_target etc '' "$uuid")"

ign() { if naming_ignored "$@"; then echo ignored; else echo used; fi; }
expect "naming: the naming of a failed move is ignored" ignored "$(ign failed /dev/disk/by-id/a /dev/disk/by-id/a)"
expect "naming: another naming is a new one" used "$(ign failed /dev/disk/by-id/a /dev/disk/by-id/b)"
expect "naming: after the naming was withdrawn, the same one is new" used "$(ign failed '' /dev/disk/by-id/a)"
expect "naming: only after a failed move" used "$(ign verified /dev/disk/by-id/a /dev/disk/by-id/a)"

due() { if cleanup_due "$@"; then echo due; else echo kept; fi; }
expect "cleanup: kept within the period" kept "$(due 1000000 7 $((1000000 + 7 * 86400 - 1)))"
expect "cleanup: due when the period is over" due "$(due 1000000 7 $((1000000 + 7 * 86400)))"
expect "cleanup: due later" due "$(due 1000000 1 2000000)"
expect "cleanup: no verification time is never due" kept "$(due '' 7 2000000)"
expect "cleanup: a damaged time is never due" kept "$(due 'x' 7 2000000)"
expect "cleanup: no period is never due" kept "$(due 1000000 '' 2000000)"

t=$(mktemp -d "$work/top.XXXXXX")
expect "top entries: lost+found alone counts as empty" "" "$(mkdir "$t/lost+found"; top_entries "$t")"
expect "top entries: everything else, sorted" $'etc\nrelease' "$(touch "$t/release"; mkdir "$t/etc"; top_entries "$t")"
a=$(mktemp -d "$work/tree.XXXXXX"); b=$(mktemp -d "$work/tree.XXXXXX")
mkdir -p "$a/_data/sub"; printf 'x' >"$a/_data/sub/f"; ln -s target "$a/_data/l"; chmod 0750 "$a/_data"
cp -a "$a/." "$b/"
expect "tree listing: a copy lists the same" same "$([ "$(tree_listing "$a")" = "$(tree_listing "$b")" ] && echo same || echo differs)"
chmod 0700 "$b/_data"
expect "tree listing: another mode differs" differs "$([ "$(tree_listing "$a")" = "$(tree_listing "$b")" ] && echo same || echo differs)"
chmod 0750 "$b/_data"; printf 'xy' >"$b/_data/sub/f"
expect "tree listing: another size differs" differs "$([ "$(tree_listing "$a")" = "$(tree_listing "$b")" ] && echo same || echo differs)"
printf 'x' >"$b/_data/sub/f"; rm "$b/_data/l"; ln -s elsewhere "$b/_data/l"
expect "tree listing: another link target differs" differs "$([ "$(tree_listing "$a")" = "$(tree_listing "$b")" ] && echo same || echo differs)"

# The move record: written whole and durably, one line per value.
records=$work/records data_disk_move=$work/records/move.env
mkdir -p "$records"
move_write --new STATE=copying UUID="$uuid" NAMED=/dev/disk/by-id/a STARTED=2026-11-14T10:00:00Z
expect "record: a field is read back" copying "$(move_get STATE)"
expect "record: no file, no field" "" "$(data_disk_move_field STATE "$work/none.env")"
move_advance copied MOVED=2026-11-14T10:05:00Z
expect "record: advanced, other fields kept" "moved|$uuid|2026-11-14T10:00:00Z|2026-11-14T10:05:00Z" \
    "$(move_get STATE)|$(move_get UUID)|$(move_get STARTED)|$(move_get MOVED)"
move_advance cleaned 2>/dev/null; rc=$?
expect "record: a step that cannot happen is refused, the record kept" "1|moved" "$rc|$(move_get STATE)"
move_advance unhealthy REASON=$'container arangodb is unhealthy\nsecond line'
expect "record: a reason stays on one line" "container arangodb is unhealthy?second line" "$(move_get REASON)"
expect "record: one line per field, comments aside" 6 "$(grep -vc '^#' "$data_disk_move")"
move_write IGNORED_NAME=
expect "record: an emptied field is dropped" "" "$(grep '^IGNORED_NAME' "$data_disk_move")"
move_write --new STATE=copying
expect "record: a new move starts from an empty record" "copying||" "$(move_get STATE)|$(move_get UUID)|$(move_get REASON)"

# replace is checked step by step: in a condition, where set -e does not
# apply, a file it cannot write is a failure, and the file stays as it was.
if [ "$(id -u)" != 0 ]; then
    ro=$(mktemp -d "$work/ro.XXXXXX")
    echo old >"$ro/f"
    chmod 0500 "$ro"
    expect "replace: a file that cannot be replaced fails, also in a condition" "failed|old" \
        "$(if echo new | replace "$ro/f" 2>/dev/null; then echo replaced; else echo failed; fi)|$(cat "$ro/f")"
    chmod 0700 "$ro"
fi

# The user file copied onto the data disk names no disk there: its naming is
# commented out, so the disk service has nothing to report as ignored.
user_on_disk() {  # user_on_disk: the user file lay_out puts on a new disk, as load reads it, and its comments
    (
        sb=$(mktemp -d "$work/layout.XXXXXX")
        mnt=$sb/disk
        mkdir -p "$mnt" "$sb/sys/etc" "$sb/sys/pinned" "$sb/bin"
        data_disk_places=("etc $sb/sys/etc" "pinned $sb/sys/pinned")
        printf 'DATA_DISK=/dev/disk/by-id/virtio-a\nDATA_DISK_FORCE=1\n  BACKUP_DISK=/dev/disk/by-id/virtio-b\r\nBACKUP_DISK_FORCE=0\nUPDATE_WINDOW=04:00\n' \
            >"$sb/sys/etc/kamerplanter.env"
        # Owner root is what lay_out enforces; as any user it is left out.
        printf '#!/bin/sh\nexit 0\n' >"$sb/bin/chown"
        chmod 0755 "$sb/bin/chown"
        PATH=$sb/bin:$PATH
        install() {
            local args=()
            while [ $# -gt 0 ]; do case $1 in -o | -g) shift 2 ;; *) args+=("$1"); shift ;; esac; done
            command install "${args[@]}"
        }
        mountpoint() { return 1; }
        lay_out || echo "lay_out failed"
        load "$mnt/etc/kamerplanter.env"
        printf '%s|%s|%s|%s|%s|%s' "$(get DATA_DISK)" "$(get DATA_DISK_FORCE)" "$(get BACKUP_DISK)" "$(get BACKUP_DISK_FORCE)" \
            "$(get UPDATE_WINDOW)" "$(grep -c '^# .*_DISK' "$mnt/etc/kamerplanter.env")"
    )
}
expect "lay_out: the user file on a new disk names no disk, the rest is kept" "||||04:00|4" "$(user_on_disk)"
nfile=$(mktemp "$work/user.XXXXXX")
printf 'UPDATE_WINDOW=04:00\n' >"$nfile"
before=$(stat -c %i "$nfile")
unname_user_file "$nfile"
expect "unname: a file without disk naming is not rewritten" "$before|UPDATE_WINDOW=04:00" "$(stat -c %i "$nfile")|$(cat "$nfile")"

# A move binds the disk only once its record says moved. move_in runs with
# set -e in effect, so a record that cannot be written stops the start before
# anything is bound (it ran in a condition before, and went on to place).
start_calls=$work/start-calls
start_move() {  # start_move CASE: cmd_start data on a disk receiving a move: the steps after the copy (start_calls), the record, the naming left in the copied user file, and the exit status
    : >"$start_calls"
    (
        set -e
        sb=$(mktemp -d "$work/start.XXXXXX")
        records=$sb/records data_disk_move=$sb/records/move.env lock=$sb/lock
        mkdir -p "$records" "$sb/sys/etc" "$sb/sys/pinned" "$sb/disk"
        printf 'DATA_DISK=/dev/disk/by-id/virtio-a\nUPDATE_WINDOW=04:00\n' >"$sb/sys/etc/kamerplanter.env"
        echo s >"$sb/sys/etc/secrets.env"
        data_disk_places=("etc $sb/sys/etc" "pinned $sb/sys/pinned")
        touch "$records/data.env"
        move_write --new STATE=copying UUID=u NAMED=/dev/disk/by-id/virtio-a
        # cmd_start sources /usr/lib/kamerplanter/env.sh, sourced here already.
        .() { :; }
        eval "real_role_vars() $(declare -f role_vars | tail -n +2)"
        eval "real_replace() $(declare -f replace | tail -n +2)"
        role_vars() { real_role_vars "$@"; mnt=$sb/disk; }
        naming() { name='' conflict='' other_name='' force=0; }
        forget_key() { :; }
        supplied_keys() { supplied=(); }
        find_and_mount() { :; }
        services_running() { :; }
        mountpoint() { return 1; }
        log_event() { :; }
        report() { :; }
        undo() { :; }
        die() { echo "die: $1"; exit 1; }
        place() { echo placed >>"$start_calls"; }
        refresh_window() { :; }
        request_check() { echo check >>"$start_calls"; }
        case $1 in
            record-fails) replace() { if [ "$1" = "$data_disk_move" ]; then cat >/dev/null; return 1; fi; real_replace "$@"; } ;;
            no-space) stat() { if [ "$1" = -f ]; then echo '1 * 1'; else command stat "$@"; fi; } ;;
        esac
        cmd_start data >/dev/null 2>&1
        printf '%s|%s' "$(move_get STATE)" "$(grep -c '^DATA_DISK=' "$sb/disk/etc/kamerplanter.env" 2>/dev/null)"
    )
    printf '|%s|%s' "$?" "$(paste -sd, "$start_calls")"
}
expect "move: copied and recorded as moved, then placed and checked; the copied user file names no disk" \
    "moved|0|0|placed,check" "$(start_move ok)"
expect "move: the record cannot say moved: the start fails, nothing is placed" "|1|" "$(start_move record-fails)"
expect "move: abandoned for lack of space: the services start, nothing is placed" "failed||0|" "$(start_move no-space)"

# Retiring the backup disk: refused with nothing changed while an update is
# not decided or something other than the naming file names the disk; else
# the naming of the backup disk, the update tool's records of the backups on
# it, its record and its key go, and the data disk's naming and records stay.
retire_with() {  # retire_with CASE [ROLE]: exit status|naming file|records|update records|keys|last line of the output
    (
        sb=$(mktemp -d "$work/retire.XXXXXX")
        records=$sb/disks naming_file=$sb/disks/naming.env user=$sb/user.env keys=$sb/disks/keys lock=$sb/lock
        update_state=$sb/update update_backups=$sb/update/backups
        credstores=("$sb/credstore") credstores_encrypted=("$sb/credstore.encrypted") retire_credstores=()
        system_credentials=$sb/system-credentials
        mkdir -p "$records/keys" "$update_backups" "$sb/credstore" "$sb/system-credentials"
        printf 'DATA_DISK=/dev/disk/by-id/virtio-a\nBACKUP_DISK=/dev/disk/by-id/virtio-b\nBACKUP_DISK_FORCE=1\n' >"$naming_file"
        touch "$records/data.env" "$records/backup.env" "$records/keys/backup.key" "$records/keys/data.key"
        printf 'LOCATION=backup-disk\n' >"$update_backups/d1"
        printf 'LOCATION=data-disk\n' >"$update_backups/d2"
        printf 'UPDATE_WINDOW=04:00\n' >"$user"
        # cmd_retire sources /usr/lib/kamerplanter/env.sh, sourced here already.
        .() { :; }
        id() { echo 0; }
        owner_problem() { :; }
        mountpoint() { return 1; }
        clear_report() { :; }
        log_event() { :; }
        # Idle: the guard stays active once done, the health check is inactive.
        systemctl() { case $4 in kamerplanter-update-health.service) echo inactive ;; *) echo active ;; esac; }
        eval "real_role_vars() $(declare -f role_vars | tail -n +2)"
        role_vars() { real_role_vars "$@" && mapper=$sb/no-mapper; }
        case $1 in
            pending) echo 'a b checking' >"$update_state/pending" ;;
            credential) echo /dev/disk/by-id/virtio-b >"$system_credentials/kamerplanter.backup-disk" ;;
            stored-credential) echo /dev/disk/by-id/virtio-b >"$sb/credstore/kamerplanter.backup-disk" ;;
            user-file) rm "$records/data.env"; echo BACKUP_DISK=/dev/disk/by-id/virtio-b >"$user" ;;
            twice) (cmd_retire backup) >/dev/null 2>&1 ;;
            guard) systemctl() { echo activating; } ;;
            health) systemctl() { echo active; } ;;
            left-mounted)
                # The record, naming, key and update record deleted by hand, not rebooted yet.
                rm "$records/backup.env" "$records/keys/backup.key" "$update_backups/d1"
                printf 'DATA_DISK=/dev/disk/by-id/virtio-a\n' >"$naming_file"
                mountpoint() { [ ! -e "$sb/unmounted" ]; }
                umount() { touch "$sb/unmounted"; }
                ;;
        esac
        out=$(cmd_retire "${2:-backup}" 2>&1)
        rc=$?
        out=${out//$sb/SB}
        printf '%s|%s|%s|%s|%s|%s' "$rc" "$(grep -v '^#' "$naming_file" | paste -sd,)" \
            "$(find "$records" -maxdepth 1 -name '*.env' ! -name naming.env -printf '%f\n' | sort | paste -sd,)" \
            "$(find "$update_backups" -mindepth 1 -printf '%f\n' | sort | paste -sd,)" \
            "$(find "$keys" -mindepth 1 -printf '%f\n' | sort | paste -sd,)" "${out##*$'\n'}"
    )
}
expect "retire: the backup disk's naming, backup records, record and key go; the data disk's stay" \
    "0|DATA_DISK=/dev/disk/by-id/virtio-a|data.env|d2|data.key|the next pre-update backup goes to the next location that may take it (see: kamerplanter-update status)" \
    "$(retire_with ok)"
expect "retire: run again, there is nothing left to retire" \
    "0|DATA_DISK=/dev/disk/by-id/virtio-a|data.env|d2|data.key|no backup disk is set up or named; nothing to retire" \
    "$(retire_with twice)"
unchanged="DATA_DISK=/dev/disk/by-id/virtio-a,BACKUP_DISK=/dev/disk/by-id/virtio-b,BACKUP_DISK_FORCE=1|backup.env,data.env|d1,d2|backup.key,data.key"
expect "retire: refused while an update is not decided, nothing changed" \
    "1|$unchanged|an update is not decided yet (see: kamerplanter-update status), and its return would restore the backup taken before it; retire the backup disk once it is decided" \
    "$(retire_with pending)"
expect "retire: refused while the guard runs, nothing changed" \
    "1|$unchanged|kamerplanter-update-guard.service is running; retire the backup disk once it is done" \
    "$(retire_with guard)"
expect "retire: refused while the health check runs (Type=exec: active), nothing changed" \
    "1|$unchanged|kamerplanter-update-health.service is running; retire the backup disk once it is done" \
    "$(retire_with health)"
expect "retire: a disk retired by hand but still mounted is unmounted, not reported as nothing to retire" \
    "0|DATA_DISK=/dev/disk/by-id/virtio-a|data.env|d2|data.key|the next pre-update backup goes to the next location that may take it (see: kamerplanter-update status)" \
    "$(retire_with left-mounted)"
expect "retire: refused while a credential from the firmware names the disk, nothing changed" \
    "1|$unchanged|the backup disk is still named by the credential kamerplanter.backup-disk in SB/system-credentials/kamerplanter.backup-disk, which would set it up again at the next start; remove that naming first; nothing is changed" \
    "$(retire_with credential)"
expect "retire: refused while a credential store names the disk, nothing changed" \
    "1|$unchanged|the backup disk is still named by the credential kamerplanter.backup-disk in SB/credstore/kamerplanter.backup-disk, which would set it up again at the next start; remove that naming first; nothing is changed" \
    "$(retire_with stored-credential)"
expect "retire: refused while the user file on the system disk names the disk, nothing changed" \
    "1|DATA_DISK=/dev/disk/by-id/virtio-a,BACKUP_DISK=/dev/disk/by-id/virtio-b,BACKUP_DISK_FORCE=1|backup.env|d1,d2|backup.key,data.key|the backup disk is still named by the setting BACKUP_DISK in SB/user.env, which would set it up again at the next start; remove that naming first; nothing is changed" \
    "$(retire_with user-file)"
expect "retire: the data disk is never retired" "2" "$(retire_with ok data | cut -d'|' -f1)"

# The configuration check checks the disk naming of the user file only where
# the disk service reads it: not on the data disk.
# shellcheck source=tests/unit/lib/sandbox.sh
. "$root/tests/unit/lib/sandbox.sh"
configure_with() {  # configure_with DATA_DISK_SET_UP USER_FILE: the exit status of configure in a sandbox
    (
        sb=$(mktemp -d "$work/configure.XXXXXX")
        sandbox_install "$sb" "$root/image/rootfs" /usr/libexec/kamerplanter/configure /usr/lib/kamerplanter/env.sh
        mkdir -p "$sb/usr/share/kamerplanter" "$sb/etc/kamerplanter" "$sb/var/lib/kamerplanter/disks" \
            "$sb/var/lib/kamerplanter/pinned" "$sb/var/mnt/kamerplanter-data" \
            "$sb/var/lib/containers/storage/volumes/arangodb_data" "$sb/var/lib/containers/storage/volumes/valkey_data"
        cp "$root/image/rootfs/usr/share/kamerplanter/kamerplanter.env" "$sb/usr/share/kamerplanter/"
        printf '%s\n' "$2" >"$sb/etc/kamerplanter/kamerplanter.env"
        MOUNTED=
        if [ "$1" = yes ]; then touch "$sb/var/lib/kamerplanter/disks/data.env"; MOUNTED=1; fi
        sandbox_mounts
        bash "$sb/usr/libexec/kamerplanter/configure" >"$sb/out" 2>&1
        echo "$?"
    )
}
bad=$'DATA_DISK=/dev/sdb\nDATA_DISK_FORCE=yes\nBACKUP_DISK=/dev/sdc'
expect "configure: no data disk, a valid naming passes" 0 "$(configure_with no 'DATA_DISK=/dev/disk/by-id/virtio-a')"
expect "configure: no data disk, an invalid naming keeps the services stopped" 1 "$(configure_with no "$bad")"
expect "configure: user file on the data disk, its naming is not checked" 0 "$(configure_with yes "$bad")"
expect "configure: user file on the data disk, other settings are still checked" 1 "$(configure_with yes 'UPDATE_WINDOW=25:00')"

if [ "$failures" -gt 0 ]; then
    echo "$failures check(s) failed"
    exit 1
fi
echo "all checks passed"
