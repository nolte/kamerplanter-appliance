#!/usr/bin/env bash
# Checks the decisions about the pre-update backup in the shared parser
# (image/rootfs/usr/lib/kamerplanter/env.sh): the locations and their order,
# the protection rule with an encrypted data disk, the space rule, the reason
# recorded when no location takes the backup, and whether a recorded backup
# can be read for a restore (spec/update-and-rollback/ D5, D8, D10;
# spec/distribution-requirements/ E8, E16). On fake input; needs no root, no
# disk and no VM.
#
# Usage: tests/unit/backup.sh
set -uo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
# shellcheck source=image/rootfs/usr/lib/kamerplanter/env.sh
. "$root/image/rootfs/usr/lib/kamerplanter/env.sh"
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

# --- the locations and where their backups are (D8, R7) ---
expect "order: backup disk, data disk, system disk" "backup-disk data-disk system-disk" "${backup_locations[*]}"
expect "system disk: the directory the update tool always used" /var/lib/kamerplanter/update/backup "$(backup_base system-disk)"
expect "backup disk: below its mount point" /var/mnt/kamerplanter-backup/update-backup "$(backup_base backup-disk)"
expect "data disk: at the top of the disk" "$data_disk_mount/update-backup" "$(backup_base data-disk)"
expect "unknown location has no base" fails "$(backup_base nowhere || echo fails)"
inside=none
base=$(backup_base data-disk)
for place in "${data_disk_places[@]}"; do
    read -r dir path <<<"$place"
    case $base/ in "$data_disk_mount/$dir"/*) inside=$dir ;; esac
    case $data_disk_mount/$dir/ in "$base"/*) inside=$dir ;; esac
done
expect "data disk: the backups are in no location of data_disk_places (E9)" none "$inside"
expect "data disk: the backups are not the release marker" yes "$([ "$base" != "$data_disk_marker" ] && [ "${data_disk_marker#"$base"/}" = "$data_disk_marker" ] && echo yes)"
expect "data disk: the backups are not in /etc/kamerplanter or a volume" yes \
    "$(case $base in /etc/kamerplanter* | /var/lib/containers/*) echo no ;; *) echo yes ;; esac)"
expect "space of the system disk is that of /var" /var "$(backup_fs system-disk)"
expect "space of the backup disk is that of its mount" /var/mnt/kamerplanter-backup "$(backup_fs backup-disk)"
expect "space of the data disk is that of its mount" "$data_disk_mount" "$(backup_fs data-disk)"

# --- space (D5): the same margin at every location ---
expect "need: nothing to copy still needs 512 MiB" 536870912 "$(backup_need 0)"
expect "need: copy plus 10 % plus 512 MiB" $((1000000000 + 100000000 + 536870912)) "$(backup_need 1000000000)"
expect "space: enough" "" "$(space_problem 2000 1000 /var)"
expect "space: exactly enough" "" "$(space_problem 1000 1000 /var)"
expect "space: short, as without any disk" "999 bytes free in /var, 1000 needed for the pre-update backup" "$(space_problem 999 1000 /var)"
expect "space: short on a disk names its mount" "5 bytes free in /var/mnt/kamerplanter-backup, 9 needed for the pre-update backup" \
    "$(space_problem 5 9 /var/mnt/kamerplanter-backup)"

# --- whether a location may take the backup (D8, E8, E16) ---
expect "system disk, data disk unencrypted" "" "$(backup_refusal system-disk ok 0 0)"
expect "backup disk present" "" "$(backup_refusal backup-disk ok 0 0)"
expect "backup disk not set up" "no backup disk kp-backup is set up" "$(backup_refusal backup-disk not-set-up 0 0)"
expect "data disk not set up" "no data disk kp-data is set up" "$(backup_refusal data-disk not-set-up 0 0)"
expect "backup disk missing" "the backup disk kp-backup is missing or not mounted" "$(backup_refusal backup-disk missing 0 0)"
expect "backup disk under another identity" "the backup disk kp-backup is mounted under another identity than the one it was set up with" \
    "$(backup_refusal backup-disk foreign 0 0)"
expect "data disk while a move onto it is unverified" "the move onto the data disk kp-data is not verified yet" "$(backup_refusal data-disk moving 0 1)"
expect "parity: encrypted data, unencrypted backup disk" "the data disk kp-data is encrypted, and the backup disk kp-backup is not" \
    "$(backup_refusal backup-disk ok 1 0)"
expect "parity: told also when that backup disk is missing" "the data disk kp-data is encrypted, and the backup disk kp-backup is not" \
    "$(backup_refusal backup-disk missing 1 0)"
expect "parity: encrypted data, encrypted backup disk" "" "$(backup_refusal backup-disk ok 1 1)"
expect "parity: encrypted backup disk with an unencrypted data disk" "" "$(backup_refusal backup-disk ok 0 1)"
expect "parity: encrypted data disk takes its own backup" "" "$(backup_refusal data-disk ok 1 1)"
expect "parity: system disk with the key kept on it" "" "$(backup_refusal system-disk ok 1 1)"
expect "parity: system disk without the key on it" "the data disk kp-data is encrypted, and its key is not kept on the system disk" \
    "$(backup_refusal system-disk ok 1 0)"
expect "parity: an encrypted, missing backup disk is missing" "the backup disk kp-backup is missing or not mounted" \
    "$(backup_refusal backup-disk missing 1 1)"

# --- the choice: refusal, then space, in the order of D8 ---
# decide BACKUP_STATE DATA_STATE DATA_ENC BACKUP_PROT SYSTEM_PROT FREE_BACKUP
# FREE_DATA FREE_SYSTEM NEED: as the update tool's assess and backup_first.
decide() {
    local states=("$1" "$2" ok) prot=("$4" "$3" "$5") free=("$6" "$7" "$8") reasons=() i r
    for i in 0 1 2; do
        r=$(backup_refusal "${backup_locations[i]}" "${states[i]}" "$3" "${prot[i]}")
        [ -n "$r" ] || r=$(space_problem "${free[i]}" "$9" "$(backup_fs "${backup_locations[i]}")")
        reasons+=("$r")
    done
    backup_first "${reasons[@]}" || echo none
}
expect "choice: no extra disk: the system disk" system-disk "$(decide not-set-up not-set-up 0 0 0 0 0 100 50)"
expect "choice: no extra disk, too little space: none" none "$(decide not-set-up not-set-up 0 0 0 0 0 49 50)"
expect "choice: backup disk present: the backup disk" backup-disk "$(decide ok ok 0 0 0 100 100 100 50)"
expect "choice: backup disk full: the data disk" data-disk "$(decide ok ok 0 0 0 10 100 100 50)"
expect "choice: backup disk full, data disk full: the system disk" system-disk "$(decide ok ok 0 0 0 10 10 100 50)"
expect "choice: every location full: none" none "$(decide ok ok 0 0 0 10 10 10 50)"
expect "choice: backup disk missing: the data disk" data-disk "$(decide missing ok 0 0 0 0 100 100 50)"
expect "choice: backup disk foreign: the data disk" data-disk "$(decide foreign ok 0 0 0 100 100 100 50)"
expect "choice: backup disk only, no data disk: the backup disk" backup-disk "$(decide ok not-set-up 0 0 0 100 0 100 50)"
expect "choice: backup disk only, full: the system disk" system-disk "$(decide ok not-set-up 0 0 0 10 0 100 50)"
expect "choice: unverified move: past the data disk to the system disk" system-disk "$(decide not-set-up moving 0 0 0 0 100 100 50)"
expect "choice: encrypted data, unencrypted backup disk: the data disk" data-disk "$(decide ok ok 1 0 1 100 100 100 50)"
expect "choice: encrypted data, encrypted backup disk: the backup disk" backup-disk "$(decide ok ok 1 1 1 100 100 100 50)"
expect "choice: encrypted data full, key on the system disk: the system disk" system-disk "$(decide ok ok 1 0 1 100 10 100 50)"
expect "choice: encrypted data full, key not on the system disk: none" none "$(decide ok ok 1 0 0 100 10 100 50)"
expect "choice: exactly the space needed counts" backup-disk "$(decide ok ok 0 0 0 50 0 0 50)"
expect "first: fewer reasons than locations" none "$(backup_first x || echo none)"

# --- the reason recorded when none takes it (D5) ---
expect "summary: the system disk alone, as without any disk" "999 bytes free in /var, 1000 needed for the pre-update backup" \
    "$(backup_summary system-disk "999 bytes free in /var, 1000 needed for the pre-update backup")"
expect "summary: every location set up, named" \
    "no location takes the pre-update backup: the backup disk kp-backup: it is full; the system disk: it is full too" \
    "$(backup_summary backup-disk "it is full" system-disk "it is full too")"

# --- whether a recorded backup can be read for a restore (D10, E8) ---
id=0d8b7c52-6f3e-4b1a-9a8e-3c1f2b4d5e6f
other=99999999-8888-7777-6666-555555555555
expect "restore: the system disk is always there" "" "$(restore_problem system-disk ok '' '')"
expect "restore: backup disk present under its identity" "" "$(restore_problem backup-disk ok "$id" "$id")"
expect "restore: identity compares case-blind" "" "$(restore_problem backup-disk ok "${id^^}" "$id")"
expect "restore: backup disk missing" "it is on the backup disk kp-backup ($id), which is missing or not mounted" \
    "$(restore_problem backup-disk missing "$id" "$id")"
expect "restore: backup disk retired" "it is on the backup disk kp-backup ($id), which is no longer set up" \
    "$(restore_problem backup-disk not-set-up "$id" '')"
expect "restore: another disk mounted as backup disk" "it is on the backup disk kp-backup ($id), but the disk mounted there has another identity" \
    "$(restore_problem backup-disk foreign "$id" "$id")"
expect "restore: another backup disk set up since" "it is on the backup disk kp-backup with the identity $id, but the disk set up there now is $other" \
    "$(restore_problem backup-disk ok "$id" "$other")"
expect "restore: no identity recorded" "it is on the data disk kp-data with the identity unknown, but the disk set up there now is $id" \
    "$(restore_problem data-disk ok '' "$id")"
expect "restore: data disk in place" "" "$(restore_problem data-disk ok "$id" "$id")"
expect "restore: parity does not matter for reading" "" "$(restore_problem backup-disk ok "$id" "$id")"

# --- the release to roll back to must find the backup (features) ---
trees=$(mktemp -d)
mkdir -p "$trees/new/usr/lib/kamerplanter" "$trees/old/usr/lib/kamerplanter" "$trees/bare/usr"
printf '# comment\nbackup-locations\n' >"$trees/new/usr/lib/kamerplanter/features"
printf '# backup-locations\nsomething-else\n' >"$trees/old/usr/lib/kamerplanter/features"
feat() { if has_feature "$1" "$2"; then echo yes; else echo no; fi; }
expect "features: this image lists backup-locations" yes "$(feat "$root/image/rootfs" backup-locations)"
expect "features: a tree that lists it" yes "$(feat "$trees/new" backup-locations)"
expect "features: listed only in a comment, or another feature" no "$(feat "$trees/old" backup-locations)"
expect "features: no features file means none" no "$(feat "$trees/bare" backup-locations)"
expect "features: no tree at all" no "$(feat "$trees/none" backup-locations)"
expect "features: no prefix match" no "$(feat "$trees/new" backup)"
printf 'backup-locations \r\n' >"$trees/new/usr/lib/kamerplanter/features"
expect "features: trailing blank and CR are ignored" yes "$(feat "$trees/new" backup-locations)"
rm -rf -- "${trees:?}"
expect "reach: a release that finds every location" "" "$(rollback_reach supported 1.4)"
expect "reach: an older release" "the release to roll back to (1.3) only finds backups on the system disk" "$(rollback_reach unsupported 1.3)"
expect "reach: an older release without version" "the release to roll back to (unversioned) only finds backups on the system disk" "$(rollback_reach unsupported '')"
expect "reach: unknown target" "the release to roll back to cannot be determined, so the backup goes where every release finds it, the system disk" \
    "$(rollback_reach unknown 1.3)"
# decide_reach SUPPORT BACKUP_STATE DATA_STATE FREE_SYSTEM: as assess with a
# rollback target: a disk that is set up gets the reach reason.
decide_reach() {
    local reach states=("$2" "$3" ok) reasons=() i r
    reach=$(rollback_reach "$1" 1.3)
    for i in 0 1 2; do
        r=$(backup_refusal "${backup_locations[i]}" "${states[i]}" 0 0)
        if [ "${backup_locations[i]}" != system-disk ] && [ "${states[i]}" != not-set-up ] && [ -n "$reach" ]; then r=$reach; fi
        [ -n "$r" ] || r=$(space_problem 100 50 /x)
        [ "${backup_locations[i]}" != system-disk ] || [ -n "$r" ] || r=$(space_problem "$4" 50 /var)
        reasons+=("$r")
    done
    backup_first "${reasons[@]}" || echo none
}
expect "target supports it: the backup disk" backup-disk "$(decide_reach supported ok ok 100)"
expect "target older: the system disk, disks present" system-disk "$(decide_reach unsupported ok ok 100)"
expect "target unknown: the system disk" system-disk "$(decide_reach unknown ok ok 100)"
expect "target older, system disk full: none, as today" none "$(decide_reach unsupported ok ok 10)"

# --- records ---
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
printf 'LOCATION=backup-disk\nUUID=%s\nSHA256=abc\nSHA256=def\n' "$id" >"$work/rec"
expect "record: a field" backup-disk "$(record_field LOCATION "$work/rec")"
expect "record: the last value counts" def "$(record_field SHA256 "$work/rec")"
expect "record: a missing field" "" "$(record_field TAKEN "$work/rec")"
expect "record: a missing file" "" "$(record_field LOCATION "$work/none")"
expect "record: no prefix match" "" "$(record_field LOC "$work/rec")"
expect "luks_uuid: from a dm-crypt mapping" "$id" "$(luks_uuid "CRYPT-LUKS2-${id//-/}-kamerplanter-backup")"
expect "luks_uuid: another mapping" "" "$(luks_uuid "LVM-abc")"

# --- writing and deleting backups never follows a link (W1) ---
# A disk prepared elsewhere may carry update-backup, or an entry in it, as a
# symbolic link to a directory of the system; root must not follow it.
D=sha256:$(printf '%064d' 1)
E=sha256:$(printf '%064d' 2)
backup_disk_mount=$work/backup-mnt data_disk_mount=$work/data-mnt system_backup_base=$work/state/backup
mkdir -p "$backup_disk_mount" "$data_disk_mount" "$work/state" "$work/victim/keep"
printf 'precious' >"$work/victim/keep/file"
victim_intact() { if [ -f "$work/victim/keep/file" ] && [ "$(ls -A "$work/victim")" = keep ]; then echo intact; else echo damaged; fi; }
yes_no() { if "$@" 2>/dev/null; then echo yes; else echo no; fi; }
expect "name: the digest of a version" yes "$(yes_no backup_name_ok "$D")"
expect "name: anything else is no backup" no "$(yes_no backup_name_ok x)"
expect "name: no path" no "$(yes_no backup_name_ok "../$D")"
expect "name: upper-case digest is not one the tool writes" no "$(yes_no backup_name_ok "sha256:$(printf '%064d' 1 | tr 0 A)")"
expect "create: a fresh backup at the backup disk" yes "$(yes_no backup_create backup-disk "$D")"
expect "create: base and backup are directories of mode 0700" "700 700" \
    "$(stat -c %a "$backup_disk_mount/update-backup") $(stat -c %a "$backup_disk_mount/update-backup/$D")"
mkdir "$backup_disk_mount/update-backup/$E" "$backup_disk_mount/update-backup/notes"
touch "$backup_disk_mount/update-backup/sha256:file"
ln -s "$work/victim" "$backup_disk_mount/update-backup/sha256:$(printf '%064d' 3)"
expect "entries: only directories named as backups, no links" "$D|$E" "$(backup_entries backup-disk | sort | paste -sd'|')"
expect "delete: a backup of its own" "yes|no" "$(yes_no backup_delete backup-disk "$E")|$([ -e "$backup_disk_mount/update-backup/$E" ] && echo yes || echo no)"
# update-backup/D -> victim: the entry as a link.
rm -rf "${backup_disk_mount:?}/update-backup/$D"
ln -s "$work/victim" "$backup_disk_mount/update-backup/$D"
expect "entry link: problem named" "$backup_disk_mount/update-backup/$D is a symbolic link" "$(backup_entry_problem backup-disk "$D")"
expect "entry link: not deleted" no "$(yes_no backup_delete backup-disk "$D")"
expect "entry link: not written into" no "$(yes_no backup_create backup-disk "$D")"
expect "entry link: the victim survives" intact "$(victim_intact)"
expect "entry link: the link stays, untouched" "$work/victim" "$(readlink "$backup_disk_mount/update-backup/$D")"
# The old cleanup's glob with a trailing slash would have reached the victim
# through this link: rm -rf "$base"/*/ deletes the target's content.
expect "entry link: not listed for the cleanup" "" "$(backup_entries backup-disk)"
# update-backup -> victim: the base as a link.
rm -rf "${backup_disk_mount:?}/update-backup"
mkdir "$work/victim/$D"
ln -s "$work/victim" "$backup_disk_mount/update-backup"
expect "base link: problem named" "$backup_disk_mount/update-backup is a symbolic link" "$(backup_base_problem backup-disk)"
expect "base link: nothing listed" "" "$(backup_entries backup-disk)"
expect "base link: not deleted" no "$(yes_no backup_delete backup-disk "$D")"
expect "base link: not written" no "$(yes_no backup_create backup-disk "$D")"
rmdir "$work/victim/$D"
expect "base link: the victim survives" intact "$(victim_intact)"
rm "$backup_disk_mount/update-backup"
touch "$backup_disk_mount/update-backup"
expect "base file: problem named" "$backup_disk_mount/update-backup is not a directory" "$(backup_base_problem backup-disk)"
rm "$backup_disk_mount/update-backup"
rmdir "$backup_disk_mount"; ln -s "$work/victim" "$backup_disk_mount"
expect "mount point as a link: not used" "$backup_disk_mount is not a directory" "$(backup_base_problem backup-disk)"
expect "mount point as a link: the victim survives" intact "$(victim_intact)"
expect "data disk: the same rules" yes "$(yes_no backup_create data-disk "$D")"
expect "data disk: deleted again" yes "$(yes_no backup_delete data-disk "$D")"
expect "system disk: the same rules" yes "$(yes_no backup_create system-disk "$D")"
expect "an unknown location" "nowhere is no location of the pre-update backup" "$(backup_base_problem nowhere)"
expect "a name that is no backup is never deleted" no "$(yes_no backup_delete system-disk ..)"
expect "deleting a missing backup succeeds" yes "$(yes_no backup_delete data-disk "$E")"

# --- the keeping period read from the data disk is bounded ---
expect "keep: the default" 7 "$(keep_days 7)"
expect "keep: longer is kept" 30 "$(keep_days 30)"
expect "keep: one day is raised to the minimum" "$backup_keep_min" "$(keep_days 1)"
expect "keep: the minimum is 3 days" 3 "$backup_keep_min"
expect "keep: not a number is the default" 7 "$(keep_days x)"
expect "keep: zero is the default" 7 "$(keep_days 0)"
expect "keep: empty is the default" 7 "$(keep_days '')"
expect "keep: too many digits is the default" 7 "$(keep_days 99999999999999999999)"

if [ "$failures" -gt 0 ]; then
    echo "$failures check(s) failed"
    exit 1
fi
echo "all checks passed"
