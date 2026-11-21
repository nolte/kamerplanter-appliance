#!/usr/bin/env bash
# Checks the decisions about the pre-update backup in the shared parser
# (image/rootfs/usr/lib/kamerplanter/env.sh): the locations and their order,
# the protection rule with an encrypted data disk, the space rule, the reason
# recorded when no location takes the backup, whether a recorded backup can
# be read for a restore, and its checksums; and the guard verifying what it
# restores (spec/update-and-rollback/ D5, D8, D10;
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

# --- the checksums of a backup (D10) ---
# legacy is what every earlier release records and verifies: a rollback to
# one of them refuses the backup unless it stays the same byte for byte. This
# is the function of kamerplanter-update that computed it, as it was.
earlier_releases_checksum() {
    local sum
    sum=$(
        {
            (cd -- "$1" && find . -mindepth 1 -printf '%y %m %U:%G %p -> %l\n' | LC_ALL=C sort) &&
                (cd -- "$1" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0r sha256sum --)
        } | sha256sum
    ) || return 1
    printf '%s' "${sum%% *}"
}
expect "checksums: getfattr is there (attr), as in the image" yes "$(command -v getfattr >/dev/null && echo yes)"
ck=$work/checksum
mkdir -p "$ck/b/arangodb_data/_data/sub" "$ck/b/valkey_data/_data"
printf 'one' >"$ck/b/arangodb_data/_data/f"
printf 'two' >"$ck/b/arangodb_data/_data/sub/g"
printf 'same' >"$ck/b/arangodb_data/_data/s1"
printf 'same' >"$ck/b/arangodb_data/_data/s2"
ln "$ck/b/arangodb_data/_data/f" "$ck/b/arangodb_data/_data/f-link"
ln -s _data/f "$ck/b/arangodb_data/current"
printf 'three' >"$ck/b/valkey_data/_data/dump.rdb"
printf 'four' >"$ck/b/valkey_data/_data/"$'a\nb'
printf '1.2\n' >"$ck/b/data-disk-release"
# Files only: a directory with mode 0644 cannot be searched.
find "$ck/b" -type f -exec chmod 0644 -- {} +
read -r legacy full <<<"$(backup_checksums both "$ck/b" .)"
expect "checksums: two SHA-256 digests" yes "$([[ $legacy =~ ^[0-9a-f]{64}$ && $full =~ ^[0-9a-f]{64}$ ]] && echo yes)"
expect "checksums: legacy is what the earlier releases verify" "$(earlier_releases_checksum "$ck/b")" "$legacy"
expect "checksums: legacy alone" "$legacy" "$(backup_checksums legacy "$ck/b" .)"
expect "checksums: full alone" "$full" "$(backup_checksums full "$ck/b" .)"
cp -a "$ck/b" "$ck/copy"
expect "checksums: a copy made by cp -a has both" "$legacy $full" "$(backup_checksums both "$ck/copy" .)"
# Restored, the volumes lie among others, the marker copy elsewhere.
mkdir -p "$ck/volumes/other_volume" "$ck/stage"
cp -a "$ck/b/arangodb_data" "$ck/b/valkey_data" "$ck/volumes/"
cp -a "$ck/b/data-disk-release" "$ck/stage/"
expect "checksums: the restored data in two places has both" "$legacy $full" \
    "$(backup_checksums both "$ck/volumes" ./arangodb_data "$ck/stage" ./data-disk-release "$ck/volumes" ./valkey_data)"
# changed COMMAND: whether legacy and full stay the same for a copy of the
# backup after COMMAND ran in it.
changed() {
    local l f
    rm -rf -- "$ck/v"
    cp -a "$ck/b" "$ck/v"
    (cd "$ck/v" && eval "$1") || { echo "command failed"; return; }
    read -r l f <<<"$(backup_checksums both "$ck/v" .)"
    printf 'legacy %s, full %s' "$([ "$l" = "$legacy" ] && echo same || echo changed)" "$([ "$f" = "$full" ] && echo same || echo changed)"
}
expect "checksums: the content" "legacy changed, full changed" "$(changed 'printf x >>arangodb_data/_data/f')"
expect "checksums: a mode" "legacy changed, full changed" "$(changed 'chmod 0600 valkey_data/_data/dump.rdb')"
expect "checksums: a file added" "legacy changed, full changed" "$(changed 'printf x >valkey_data/_data/new')"
expect "checksums: a link target" "legacy changed, full changed" "$(changed 'ln -sfn _data/sub arangodb_data/current')"
expect "checksums: an extended attribute" "legacy same, full changed" "$(changed 'setfattr -n user.kamerplanter -v x valkey_data/_data/dump.rdb')"
expect "checksums: an extended attribute of a directory" "legacy same, full changed" "$(changed 'setfattr -n user.kamerplanter -v x arangodb_data')"
expect "checksums: an ACL" "legacy same, full changed" "$(changed 'setfacl -m u:0:r valkey_data/_data/dump.rdb')"
expect "checksums: a default ACL" "legacy same, full changed" "$(changed 'setfacl -d -m u:0:rx arangodb_data/_data/sub')"
expect "checksums: hard links split into copies" "legacy same, full changed" \
    "$(changed 'rm arangodb_data/_data/f-link && cp -p arangodb_data/_data/f arangodb_data/_data/f-link')"
expect "checksums: copies joined into hard links" "legacy same, full changed" "$(changed 'ln -f arangodb_data/_data/s1 arangodb_data/_data/s2')"
expect "checksums: a hard link to a file outside does not count" "legacy same, full same" "$(changed "ln arangodb_data/_data/sub/g '$ck/outside'")"
rm -f -- "$ck/outside"
# Paths that legacy cannot tell apart: x -> y pointing at z, x pointing at y -> z.
mkdir -p "$ck/l1" "$ck/l2"
ln -s z "$ck/l1/x -> y"
ln -s "y -> z" "$ck/l2/x"
expect "checksums: legacy cannot tell those links apart" "$(backup_checksums legacy "$ck/l1" .)" "$(backup_checksums legacy "$ck/l2" .)"
expect "checksums: full can" yes "$([ "$(backup_checksums full "$ck/l1" .)" != "$(backup_checksums full "$ck/l2" .)" ] && echo yes)"
expect "checksums: a directory that cannot be read fails" fails "$(backup_checksums both "$ck/none" . || echo fails)"

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

# --- the update tool as it ships, in a sandbox (lib/sandbox.sh) ---
# shellcheck source=tests/unit/lib/sandbox.sh
. "$root/tests/unit/lib/sandbox.sh"
OLD=sha256:$(printf '%064d' 7) NEW=sha256:$(printf '%064d' 8)
checksum=$(printf '%064d' 9)
# new_sandbox [FEATURES]: a fresh tree for kamerplanter-update in SB, running
# 1.2 ($NEW) with 1.1 ($OLD) as bootc's rollback deployment, whose tree lists
# FEATURES (one per line). The disk service is a stub that notes each call,
# and whether the update lock was held then.
new_sandbox() {
    SB=$(mktemp -d "$work/sandbox.XXXXXX")
    sandbox_install "$SB" "$root/image/rootfs" /usr/bin/kamerplanter-update /usr/lib/kamerplanter/env.sh
    st=$SB/var/lib/kamerplanter/update
    mkdir -p "$st/backups" "$st/backup" "$SB/var/lib/kamerplanter/disks" "$SB/var/lib/kamerplanter/pinned" \
        "$SB/var/mnt/kamerplanter-data" "$SB/etc/kamerplanter" "$SB/usr/share/kamerplanter" "$SB/usr/libexec/kamerplanter" \
        "$SB/var/lib/containers/storage/volumes/arangodb_data" "$SB/var/lib/containers/storage/volumes/valkey_data" \
        "$SB/sysroot/ostree/deploy/default/deploy/$checksum.0/usr/lib/kamerplanter"
    cp "$root/image/rootfs/usr/share/kamerplanter/kamerplanter.env" "$SB/usr/share/kamerplanter/"
    printf '%s\n' "${1-}" >"$SB/sysroot/ostree/deploy/default/deploy/$checksum.0/usr/lib/kamerplanter/features"
    cat >"$SB/usr/libexec/kamerplanter/disks" <<STUB
#!/bin/bash
if flock -n "$st/.lock" true; then l=unlocked; else l=locked; fi
echo "\$1 \${2-} \$l" >>"$SB/disks-calls"
STUB
    chmod 0755 "$SB/usr/libexec/kamerplanter/disks"
    jq -n --arg old "$OLD" --arg new "$NEW" --arg sum "$checksum" '{status: {
        booted: {image: {imageDigest: $new, version: "1.2", image: {image: "ghcr.io/example/appliance:stable", transport: "registry"}}},
        rollback: {image: {imageDigest: $old, version: "1.1", image: {image: "ghcr.io/example/appliance:stable", transport: "registry"}},
                   ostree: {stateroot: "default", checksum: $sum, deploySerial: 0}}}}' >"$SB/bootc.json"
}
# The commands that reach the system, as the tool calls them.
bootc() {
    case $1 in
        status)
            echo x >>"$SB/bootc-status"
            if [ -n "${BOOTC_STATUS_FAILS_FROM-}" ] && [ "$(wc -l <"$SB/bootc-status")" -ge "$BOOTC_STATUS_FAILS_FROM" ]; then return 1; fi
            cat "$SB/bootc.json"
            ;;
        *) echo "bootc $*" >>"$SB/calls" ;;
    esac
}
skopeo() { if [ -n "${SKOPEO_OFFERS-}" ]; then echo "$SKOPEO_OFFERS"; else echo "no network" >&2; return 1; fi; }
systemctl() {
    case "$1 ${3-}" in
        "is-active kamerplanter-config.service") echo x >>"$SB/health-checks"; [ -z "${UNHEALTHY-}" ] ;;
        is-active*) [ -z "${UNHEALTHY-}" ] ;;
        *) return 0 ;;
    esac
}
podman() { echo healthy; }
curl() { return 0; }
agetty() { return 0; }
sleep() { return 0; }
# The clock jumps far ahead after the first look, so a health check that
# fails has used its time at once.
date() {
    if [ "$*" = +%s ]; then
        if [ -e "$SB/clock" ]; then echo 4000000000; else touch "$SB/clock"; command date +%s; fi
    else
        command date "$@"
    fi
}
# tool ARGS...: runs the sandboxed tool; prints its exit status.
tool() {
    (
        sandbox_mounts
        export SB BOOTC_STATUS_FAILS_FROM SKOPEO_OFFERS UNHEALTHY
        export -f bootc skopeo systemctl podman curl agetty sleep date
        bash "$SB/usr/bin/kamerplanter-update" "$@" </dev/null >>"$SB/out" 2>&1
        echo $?
    )
}
lines() { if [ -e "$1" ]; then paste -sd'|' "$1"; fi; }
# A pre-update backup on the system disk, due for deletion, and a verified
# move whose system copy the disk service deletes in the same cleanup.
due_backup() {
    printf 'LOCATION=system-disk\nSHA256=x\nTAKEN=2000-01-01T00:00:00Z\n' >"$st/backups/$OLD"
    mkdir -p "$st/backup/$OLD"
    printf 'STATE=verified\nVERIFIED=2000-01-01T00:00:00Z\n' >"$SB/var/lib/kamerplanter/disks/move.env"
}

# The cleanup after a fetch runs under the update lock, and not at all
# without it (finding: it ran unlocked after the fetch's subshell).
new_sandbox backup-locations; due_backup
held_by_other=$( (exec 8>"$st/.lock"; flock -n 8 && tool fetch) )
expect "fetch: another action holds the lock: it fails" 1 "$held_by_other"
expect "fetch: another action holds the lock: no cleanup, the backup stays" "yes|" \
    "$([ -d "$st/backup/$OLD" ] && echo yes || echo no)|$(lines "$SB/disks-calls")"
new_sandbox backup-locations; due_backup
expect "fetch: offline, the fetch fails" 1 "$(tool fetch)"
expect "fetch: offline, the cleanup runs all the same, under the lock" "no|cleanup 7 locked" \
    "$([ -d "$st/backup/$OLD" ] && echo yes || echo no)|$(lines "$SB/disks-calls")"

# apply-now keeps set -e inside the fetch: bootc failing after the download
# stops it, instead of recording a staged update that is not known.
new_sandbox backup-locations
rc=$(BOOTC_STATUS_FAILS_FROM=2 SKOPEO_OFFERS="sha256:$(printf '%064d' 5) 1.3" tool apply-now)
expect "apply-now: bootc failing after the download stops the fetch" "failed|" \
    "$([ "$rc" != 0 ] && echo failed || echo "succeeded ($rc)")|$(grep -o '"event":"fetch","result":"staged"' "$st/log.jsonl" 2>/dev/null)"

# A manual rollback to a release without data disks is refused while one is
# set up: it would run on the system disk's copy, or on nothing.
new_sandbox backup-locations
mkdir -p "$st/backup/$OLD"
touch "$SB/var/lib/kamerplanter/disks/data.env"
expect "rollback: data disk set up, target without data-disk: refused" "1||" \
    "$(tool rollback)|$(lines "$SB/calls")|$(cat "$st/pending" 2>/dev/null)"
expect "rollback: the refusal says why" yes "$(grep -q 'does not know data disks' "$SB/out" && echo yes)"
rm -rf "$SB/sysroot"
expect "rollback: data disk set up, target tree not found: refused" "1|" "$(tool rollback)|$(lines "$SB/calls")"
new_sandbox "$(printf 'backup-locations\ndata-disk')"
mkdir -p "$st/backup/$OLD"
touch "$SB/var/lib/kamerplanter/disks/data.env"
expect "rollback: target with data-disk: returned to" "0|bootc rollback --apply|$OLD $NEW manual" \
    "$(tool rollback)|$(lines "$SB/calls")|$(cat "$st/pending")"
new_sandbox backup-locations
mkdir -p "$st/backup/$OLD"
expect "rollback: no data disk, target without data-disk: returned to" "0|bootc rollback --apply" \
    "$(tool rollback)|$(lines "$SB/calls")"

# The automatic return after a failed update is never refused; a move onto a
# data disk the target does not know is returned to the system copy first.
new_sandbox backup-locations
printf '%s %s checking\n' "$OLD" "$NEW" >"$st/pending"
touch "$SB/var/lib/kamerplanter/disks/data.env"
printf 'STATE=moved\n' >"$SB/var/lib/kamerplanter/disks/move.env"
expect "health: failed update, target without data-disk: the move is returned, then the version" \
    "1|move unhealthy unlocked|bootc rollback --apply" "$(UNHEALTHY=1 tool health)|$(lines "$SB/disks-calls")|$(lines "$SB/calls")"
new_sandbox "$(printf 'backup-locations\ndata-disk')"
printf '%s %s checking\n' "$OLD" "$NEW" >"$st/pending"
touch "$SB/var/lib/kamerplanter/disks/data.env"
printf 'STATE=moved\n' >"$SB/var/lib/kamerplanter/disks/move.env"
expect "health: failed update, target with data-disk: only the version returns" \
    "1||bootc rollback --apply" "$(UNHEALTHY=1 tool health)|$(lines "$SB/disks-calls")|$(lines "$SB/calls")"

# After a move, one health check decides the move and the release marker.
new_sandbox backup-locations
touch "$SB/var/lib/kamerplanter/disks/data.env"
printf 'STATE=moved\n' >"$SB/var/lib/kamerplanter/disks/move.env"
expect "health: after a move, healthy" 0 "$(MOUNTED=1 tool health)"
expect "health: after a move, the services are checked once" 1 "$(wc -l <"$SB/health-checks")"
expect "health: after a move, the move is verified and the disk marked" "move healthy unlocked|1.2" \
    "$(lines "$SB/disks-calls")|$(cat "$SB/var/mnt/kamerplanter-data/release")"

# The backup the guard takes on the first boot of a new version carries
# both checksums: SHA256 for the release it returns to, SHA256_FULL for this.
new_sandbox backup-locations
vol=$SB/var/lib/containers/storage/volumes
echo "$OLD" >"$st/good"
mkdir -p "$vol/arangodb_data/_data"
printf 'data' >"$vol/arangodb_data/_data/f"
expect "guard: first boot of the new version takes the backup" 0 "$(tool guard)"
read -r legacy full <<<"$(backup_checksums both "$st/backup/$OLD" .)"
expect "guard: the record holds the checksum the earlier releases verify" "$(earlier_releases_checksum "$st/backup/$OLD")" \
    "$(record_field SHA256 "$st/backups/$OLD")"
expect "guard: the record holds the full checksum" "$full" "$(record_field SHA256_FULL "$st/backups/$OLD")"

# restore_sandbox RECORD: booted on $NEW again after the update to $OLD
# failed, with the backup of $NEW on the system disk and the data of $OLD in
# the volumes; the record of the backup holds both checksums (both), only
# SHA256 as an earlier release writes it (legacy), or there is none (none).
restore_sandbox() {
    local b l f
    new_sandbox backup-locations
    vol=$SB/var/lib/containers/storage/volumes
    echo "$NEW" >"$st/good"
    printf '%s %s checking\n' "$NEW" "$OLD" >"$st/pending"
    b=$st/backup/$NEW
    mkdir -p "$b/arangodb_data/_data" "$b/valkey_data/_data"
    printf 'before' >"$b/arangodb_data/_data/f"
    printf 'cache' >"$b/valkey_data/_data/dump.rdb"
    printf 'after' >"$vol/arangodb_data/f-of-the-new-version"
    read -r l f <<<"$(backup_checksums both "$b" .)"
    case $1 in
        both) printf 'LOCATION=system-disk\nSHA256=%s\nSHA256_FULL=%s\nTAKEN=2000-01-01T00:00:00Z\n' "$l" "$f" >"$st/backups/$NEW" ;;
        legacy) printf 'LOCATION=system-disk\nSHA256=%s\nTAKEN=2000-01-01T00:00:00Z\n' "$l" >"$st/backups/$NEW" ;;
    esac
}
restored() {
    if [ "$(cat "$vol/arangodb_data/_data/f" 2>/dev/null)" = before ] && [ ! -e "$vol/arangodb_data/f-of-the-new-version" ]; then
        echo restored
    else
        echo "not restored"
    fi
}
for record in both legacy none; do
    restore_sandbox "$record"
    expect "guard: a backup recorded with $record is restored" "0|restored|" "$(tool guard)|$(restored)|$(cat "$st/pending" 2>/dev/null)"
    expect "guard: nothing of the restore is left in the update state ($record)" "" "$(find "$st" -maxdepth 1 -name 'restore.*')"
done
restore_sandbox both
setfattr -n user.kamerplanter -v x "$st/backup/$NEW/valkey_data/_data/dump.rdb"
expect "guard: an extended attribute added to the backup: not restored, the services stay stopped" "1|not restored|$NEW $OLD checking" \
    "$(tool guard)|$(restored)|$(cat "$st/pending")"
expect "guard: the refusal names the checksum" yes "$(grep -q 'does not match the checksum recorded when it was taken' "$SB/out" && echo yes)"
# A disk that returns other data when the backup is read again: what was
# copied is verified, not what was read before (cp is the second read).
restore_sandbox both
# shellcheck disable=SC2329 # called by the tool it is exported to
cp() {
    command cp "$@" || return
    case ${!#} in */volumes/arangodb_data) printf 'x' >>"${!#}/_data/f" ;; esac
}
rc=$(export -f cp; tool guard)
unset -f cp
expect "guard: other data on the second read: the services stay stopped, the restore is tried again" "1|$NEW $OLD checking" \
    "$rc|$(cat "$st/pending")"
expect "guard: the failure names the checksum of what was copied" yes \
    "$(grep -q 'what was copied does not match the checksum recorded with the backup' "$st/log.jsonl" && echo yes)"
expect "guard: no rollback is recorded as done" "" "$(grep -o '"result":"done"' "$st/log.jsonl")"
expect "guard: the console says why" yes "$(grep -q 'what was copied does not match' "$SB/run/issue.d/45-kamerplanter-restore.issue" 2>/dev/null && echo yes)"
expect "guard: the console does not call the checked backup damaged" yes "$(grep -q 'the backup passed its check' "$SB/run/issue.d/45-kamerplanter-restore.issue" 2>/dev/null && ! grep -q 'damaged or gone' "$SB/run/issue.d/45-kamerplanter-restore.issue" && echo yes)"

if [ "$failures" -gt 0 ]; then
    echo "$failures check(s) failed"
    exit 1
fi
echo "all checks passed"
