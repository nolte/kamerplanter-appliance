# shellcheck shell=bash
# Reads the Kamerplanter configuration files; sourced at the top level, not
# run. Every reader uses it: the configuration check
# (/usr/libexec/kamerplanter/configure), the update tool
# (/usr/bin/kamerplanter-update) and the maintenance window generator
# (/usr/lib/systemd/system-generators/kamerplanter-update-window), so a value
# means the same to all of them.
#
# KEY=VALUE per line, the value taken literally. A trailing CR, leading
# whitespace, empty lines and comments are dropped; every other line that is
# not KEY=VALUE is listed in cfg_invalid. Later files win, missing files are
# skipped.
#
# It also names the locations of the data disk (data_disk_places below),
# which the disk service binds and every writer checks, the record of a move
# onto the data disk (data_disk_move), and holds the release comparison and
# the release marker of the data disk (release_version below), and the
# locations of the pre-update backup with the decisions about them
# (backup_locations below).
declare -A cfg
cfg_invalid=()
load() {
    cfg=()
    cfg_invalid=()
    local file line number key
    for file in "$@"; do
        [ -e "$file" ] || continue
        number=0
        while IFS= read -r line || [ -n "$line" ]; do
            number=$((number + 1))
            line=${line%$'\r'}
            line=${line#"${line%%[![:space:]]*}"}
            case $line in '' | '#'*) continue ;; esac
            key=${line%%=*}
            if [[ $line != *=* || ! $key =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
                cfg_invalid+=("line $number of $file is not KEY=VALUE")
                continue
            fi
            cfg[$key]=${line#*=}
        done <"$file"
    done
}
get() { printf '%s' "${cfg[$1]-}"; }

# disk_path_ok PATH: whether PATH names a disk the only way
# spec/distribution-requirements/ E7 allows, /dev/disk/by-id/NAME or
# /dev/disk/by-uuid/NAME, with NAME one path component in the characters udev
# uses for these links. The configuration check and the disk service
# (/usr/libexec/kamerplanter/disks) both test a naming with it.
disk_path_ok() {
    local re='^/dev/disk/by-(id|uuid)/[-0-9A-Za-z#+.:=@_]+$'
    [[ $1 =~ $re ]] && [ "${1##*/}" != . ] && [ "${1##*/}" != .. ]
}

# user_file_trusted [RECORD]: whether the user file
# /etc/kamerplanter/kamerplanter.env may name disks (DATA_DISK, BACKUP_DISK
# and their *_FORCE): only while it lies on the system disk, since no data
# disk is set up (RECORD, by default data_disk_record below, is missing) and
# nothing is mounted onto /etc/kamerplanter. On a data disk it may have been
# changed elsewhere, so the disk service ignores those keys there, and the
# configuration check does not check them.
user_file_trusted() {
    [ ! -e "${1:-$data_disk_record}" ] && ! mountpoint -q /etc/kamerplanter
}

# The data disk (spec/distribution-requirements/ E6, E9). It is set up when
# its record exists and is mounted at data_disk_mount. Each entry of
# data_disk_places, "DIRECTORY PATH", is a directory on the disk that the
# disk service (/usr/libexec/kamerplanter/disks) binds onto the PATH the
# readers use, so configure, the update tool, the window generator and Podman
# keep their paths with and without a data disk. The update state
# (/var/lib/kamerplanter/update/) and the disk records
# (/var/lib/kamerplanter/disks/) stay on the system disk
# (spec/update-and-rollback/ D9).
data_disk_record=/var/lib/kamerplanter/disks/data.env
data_disk_mount=/var/mnt/kamerplanter-data
data_disk_places=(
    "etc /etc/kamerplanter"
    "pinned /var/lib/kamerplanter/pinned"
    "volumes/arangodb_data /var/lib/containers/storage/volumes/arangodb_data"
    "volumes/valkey_data /var/lib/containers/storage/volumes/valkey_data"
)

# bound_from DIRECTORY PATH: whether the top mount at PATH is DIRECTORY of the
# file system mounted at data_disk_mount.
bound_from() {
    mountpoint -q -- "$2" || return 1
    [ "$(stat -c %d -- "$2")" = "$(stat -c %d -- "$data_disk_mount")" ] || return 1
    [ "$(findmnt -rno FSROOT -M "$2" | tail -n1)" = "/$1" ]
}

# data_disk_placed: succeeds when no data disk is set up, or when it is
# mounted and every location of data_disk_places is bound from it. Whatever
# writes the configuration or the data checks this first, so that nothing is
# ever written to the system disk underneath a location of the data disk.
data_disk_placed() {
    [ -e "$data_disk_record" ] || return 0
    mountpoint -q -- "$data_disk_mount" || return 1
    local place dir path
    for place in "${data_disk_places[@]}"; do
        read -r dir path <<<"$place"
        bound_from "$dir" "$path" || return 1
    done
}

# data_disk_present: whether the device the data disk is mounted from still
# answers: a direct read of its first block, past the page cache. A disk
# pulled or failed while mounted keeps its mount, so the mount alone does not
# tell (spec/distribution-requirements/ E11, E12: a missing disk is no failed
# start).
data_disk_present() { mount_present "$data_disk_mount"; }

# mount_present MOUNT: whether the device mounted at MOUNT still answers, read
# as data_disk_present reads it; the backup disk is checked the same way.
mount_present() {
    local src
    mountpoint -q -- "$1" || return 1
    src=$(findmnt -rnvo SOURCE -M "$1" 2>/dev/null | tail -n1)
    [ -b "$src" ] || return 1
    dd if="$src" of=/dev/null bs=4096 count=1 iflag=direct status=none 2>/dev/null
}

# luks_uuid DM_UUID: the UUID of the LUKS2 container a dm-crypt mapping was
# opened from, taken from the mapping's device-mapper UUID
# (CRYPT-LUKS2-<UUID without dashes>-<NAME>); empty for any other mapping.
luks_uuid() {
    local re='^CRYPT-LUKS2-([0-9A-Fa-f]{32})-' h
    [[ $1 =~ $re ]] || return 0
    h=${BASH_REMATCH[1],,}
    printf '%s-%s-%s-%s-%s' "${h:0:8}" "${h:8:4}" "${h:12:4}" "${h:16:4}" "${h:20:12}"
}

# mounted_uuid MOUNT: the identity of the disk mounted at MOUNT as the disk
# service records it (spec/distribution-requirements/ E8): the LUKS2 UUID
# when it is mounted from an opened container, else the UUID of its file
# system, in lower case; empty when nothing is mounted there.
mounted_uuid() {
    local src k u
    mountpoint -q -- "$1" || return 0
    src=$(findmnt -rnvo SOURCE -M "$1" 2>/dev/null | tail -n1)
    [ -b "$src" ] || return 0
    k=$(lsblk -nrdo KNAME -- "$src" 2>/dev/null || true)
    if [ -n "$k" ]; then u=$(luks_uuid "$(cat "/sys/class/block/$k/dm/uuid" 2>/dev/null || true)"); fi
    if [ -z "${u-}" ]; then u=$(blkid -p -o value -s UUID -- "$src" 2>/dev/null || true); fi
    printf '%s' "${u,,}"
}

# The move of an appliance's data from the system disk onto a newly named
# data disk (spec/distribution-requirements/ E11), recorded on the system disk
# by the disk service (/usr/libexec/kamerplanter/disks, which explains the
# states). One KEY=VALUE per line; STATE is copying, moved, verified,
# cleaned, falling-back or failed. The update tool reads it to check the
# services after a move and to delete the system copy once it may.
data_disk_move=/var/lib/kamerplanter/disks/move.env

# data_disk_move_field KEY [FILE]: the value of KEY in the move record; empty
# when there is none.
data_disk_move_field() { record_field "$1" "${2:-$data_disk_move}"; }

# record_field KEY FILE: the value of KEY in a record of KEY=VALUE lines (the
# disk records, the move record, the backup records); empty when FILE or KEY
# is missing.
record_field() {
    [ -f "$2" ] || return 0
    sed -n "s/^$1=//p" -- "$2" | tail -n1
}

# cleanup_due SINCE DAYS NOW: whether something kept for DAYS days
# (UPDATE_BACKUP_KEEP_DAYS) from SINCE may be deleted at NOW, all in epoch
# seconds: the system disk's copy of data moved onto the data disk, from the
# time the services passed the health check from it, and a pre-update backup,
# from the time it was taken. A time that is not a number is never due.
cleanup_due() {
    [[ $1 =~ ^[0-9]+$ && $2 =~ ^[0-9]+$ && $3 =~ ^[0-9]+$ ]] || return 1
    [ "$3" -ge $(($1 + $2 * 86400)) ]
}

# Releases (spec/update-and-rollback/ A4, A7). One comparison serves the
# update tool, which offers and activates only newer releases, and the release
# marker of the data disk below, which keeps an older release off a disk a
# newer one has used.
#
# Releases are versioned X.Y or X.Y.Z, optionally with a leading v (the
# release tag); anything else is a development build.
release_version() {
    local v=${1#v}
    [[ $v =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || return 1
    printf '%s' "$v"
}
# forward CANDIDATE RUNNING: whether version CANDIDATE may follow RUNNING
# (spec A4): a release only after an older release. A development build runs
# anything after it, and is never accepted after a release.
forward() {
    local candidate running
    running=$(release_version "$2") || return 0
    candidate=$(release_version "$1") || return 1
    [ "$candidate" != "$running" ] &&
        [ "$(printf '%s\n%s\n' "$running" "$candidate" | sort -V | tail -n1)" = "$candidate" ]
}

# The release marker (spec/distribution-requirements/ E13): the file
# "release" at the top of the data disk holds the highest release whose
# services passed the health check of spec/update-and-rollback/ E1 on it. It
# lies outside every location of data_disk_places, so it is neither part of
# /etc/kamerplanter, which configure reads and the deployments merge, nor of a
# volume a container writes to. The update tool (/usr/bin/kamerplanter-update)
# raises it, checks it before any container starts, and keeps a copy with
# every pre-update backup; nothing else of the update state is on the disk.
data_disk_marker=$data_disk_mount/release

# data_disk_release: the release the marker of a set-up, mounted data disk
# holds; empty when no data disk is set up, it is not mounted, or it carries
# no marker; "unreadable" when the marker is not a regular file or holds no
# release. Reads only, and at most 64 bytes.
data_disk_release() {
    [ -e "$data_disk_record" ] && mountpoint -q -- "$data_disk_mount" || return 0
    [ -e "$data_disk_marker" ] || [ -L "$data_disk_marker" ] || return 0
    local line
    if [ -f "$data_disk_marker" ] && [ ! -L "$data_disk_marker" ] &&
        line=$(head -c 64 -- "$data_disk_marker" 2>/dev/null) && release_version "${line%%$'\n'*}"; then
        return 0
    fi
    printf unreadable
}

# marker_refuses MARKER RUNNING: whether the release RUNNING keeps the
# services stopped on a data disk whose marker holds MARKER (E13). No marker
# (MARKER empty) refuses nothing. A marker newer than RUNNING refuses, decided
# by forward; an unreadable marker refuses every release, since the release
# that wrote it is unknown. A development build counts as older than any
# release (forward): it is refused on every marked disk, also on one marked
# by the oldest release, and runs only on a disk without a marker.
marker_refuses() {
    [ -n "$1" ] || return 1
    release_version "$1" >/dev/null || return 0
    forward "$1" "$2"
}

# marker_raises RUNNING MARKER: whether the release RUNNING, once its services
# passed the health check, writes itself into a marker that holds MARKER: only
# a release, and only over no marker, an older one or an unreadable one. A
# development build never writes the marker, so it never raises one a release
# set and leaves an unmarked disk unmarked.
marker_raises() {
    release_version "$1" >/dev/null || return 1
    [ -z "$2" ] || forward "$1" "$2"
}

# downgrade_allowed MARKER RUNNING FILE: whether FILE, the overrides that
# `kamerplanter-update allow-downgrade` records in the update state, lets the
# release RUNNING use a disk marked MARKER. One line "MARKER RUNNING TIME"
# per override; an override holds only for its own pair.
downgrade_allowed() {
    [ -f "$3" ] || return 1
    awk -v m="$1" -v r="$2" '$1 == m && $2 == r { found = 1 } END { exit !found }' "$3"
}

# ---------------------------------------------------------------------------
# Where the pre-update backup goes (spec/update-and-rollback/ D2, D5, D8,
# D10). The update tool (/usr/bin/kamerplanter-update) takes it, restores
# it, and deletes it; the decisions below have no side effects, and
# tests/unit/backup.sh checks them.
#
# The locations, in the order of D8: the backup disk, the data disk, the
# system disk. A backup of the version D is the directory D below the
# location's base (backup_base): the volumes of data_volumes in the update
# tool, and a copy of the release marker of the data disk (data-disk-release).
# On the data disk the base lies at the top of the disk, outside every
# location of data_disk_places and beside the release marker, so a backup is
# never part of /etc/kamerplanter or a volume; on the system disk it is the
# directory the update tool always used. Where each backup is, and its
# checksum, is recorded in the update state on the system disk
# (spec/update-and-rollback/ D9, D10).
backup_disk_mount=/var/mnt/kamerplanter-backup
backup_locations=(backup-disk data-disk system-disk)

# backup_first REASON...: the first location of backup_locations whose
# REASON, given in that order, is empty, the one that takes the backup;
# fails when every location has a reason not to.
backup_first() {
    local i=0 loc
    for loc in "${backup_locations[@]}"; do
        i=$((i + 1))
        [ $i -le $# ] || return 1
        if [ -z "${!i}" ]; then printf '%s' "$loc"; return 0; fi
    done
    return 1
}

system_backup_base=/var/lib/kamerplanter/update/backup

# backup_base LOCATION: the directory the backups at LOCATION are kept in.
backup_base() {
    case $1 in
        backup-disk) printf '%s' "$backup_disk_mount/update-backup" ;;
        data-disk) printf '%s' "$data_disk_mount/update-backup" ;;
        system-disk) printf '%s' "$system_backup_base" ;;
        *) return 1 ;;
    esac
}

# backup_root LOCATION: the directory the base of LOCATION lies in, and on
# whose file system it must be: the mount point of the disk, or the update
# state on the system disk.
backup_root() {
    case $1 in
        backup-disk) printf '%s' "$backup_disk_mount" ;;
        data-disk) printf '%s' "$data_disk_mount" ;;
        system-disk) printf '%s' "${system_backup_base%/*}" ;;
        *) return 1 ;;
    esac
}

# Deleting and writing backups. A disk, a USB stick above all, may have been
# prepared elsewhere: its update-backup, or an entry in it, may be a symbolic
# link to anywhere on the system, which root would follow. So a backup is
# written or deleted only as a directory of its own, named as the update tool
# names it (backup_name_ok), directly in a base that is a directory of its
# own, both on the file system of the location; anything else at a location
# is left alone, and never followed.

# backup_name_ok NAME: whether NAME is the name of a backup: the digest of
# the version it was taken when leaving (sha256:<64 hex digits>).
backup_name_ok() { [[ $1 =~ ^sha256:[0-9a-f]{64}$ ]]; }

# backup_base_problem LOCATION: why no backup is written to or deleted at
# LOCATION; empty when its base may be used. Its root must be a directory,
# and its base, when it exists, a directory on the same file system; neither
# may be a symbolic link. Reads only.
backup_base_problem() {
    local root base
    if ! root=$(backup_root "$1") || ! base=$(backup_base "$1"); then
        echo "$1 is no location of the pre-update backup"
        return
    fi
    if [ -L "$root" ] || [ ! -d "$root" ]; then echo "$root is not a directory"; return; fi
    if [ -L "$base" ]; then echo "$base is a symbolic link"; return; fi
    [ -e "$base" ] || return 0
    if [ ! -d "$base" ]; then echo "$base is not a directory"; return; fi
    [ "$(stat -c %d -- "$base")" = "$(stat -c %d -- "$root")" ] || echo "$base is on another file system than $root"
}

# backup_entry_problem LOCATION NAME: why the backup NAME at LOCATION is not
# written, restored or deleted; empty when it may be: NAME is the name of a
# backup, the base may be used, and the backup, when it exists, is a
# directory on the file system of the base, not a symbolic link. Reads only.
backup_entry_problem() {
    local problem dir
    backup_name_ok "$2" || { echo "the name of the backup is not the digest of a version"; return; }
    problem=$(backup_base_problem "$1")
    if [ -n "$problem" ]; then echo "$problem"; return; fi
    dir=$(backup_base "$1")/$2
    if [ -L "$dir" ]; then echo "$dir is a symbolic link"; return; fi
    [ -e "$dir" ] || return 0
    if [ ! -d "$dir" ]; then echo "$dir is not a directory"; return; fi
    [ "$(stat -c %d -- "$dir")" = "$(stat -c %d -- "$(backup_base "$1")")" ] || echo "$dir is on another file system"
}

# backup_entries LOCATION: the names of the backups at LOCATION, one per
# line: the directories directly in its base, on its file system, named as a
# backup. Symbolic links, files and other names are not listed; nothing is
# when the base may not be used.
backup_entries() {
    local base dev d name
    [ -z "$(backup_base_problem "$1")" ] || return 0
    base=$(backup_base "$1")
    [ -d "$base" ] || return 0
    dev=$(stat -c %d -- "$base")
    while IFS=' ' read -r -d '' d name; do
        if [ "$d" = "$dev" ] && backup_name_ok "$name"; then printf '%s\n' "$name"; fi
    done < <(find "$base" -mindepth 1 -maxdepth 1 -type d -printf '%D %f\0')
}

# backup_delete LOCATION NAME: deletes the backup NAME at LOCATION, never
# through a symbolic link and never on another file system; fails, deleting
# nothing, when backup_entry_problem names a problem, and says it.
backup_delete() {
    local problem dir
    problem=$(backup_entry_problem "$1" "$2")
    if [ -n "$problem" ]; then
        echo "$problem; nothing is deleted there" >&2
        return 1
    fi
    dir=$(backup_base "$1")/$2
    [ -e "$dir" ] || return 0
    rm -rf --one-file-system -- "$dir"
}

# backup_create LOCATION NAME: an empty directory (0700) for the backup NAME
# at LOCATION, in place of an earlier one; the base is created when missing,
# never over a link. Fails, and says why, when backup_entry_problem names a
# problem.
backup_create() {
    local problem base
    problem=$(backup_entry_problem "$1" "$2")
    if [ -n "$problem" ]; then
        echo "$problem; no backup is written there" >&2
        return 1
    fi
    base=$(backup_base "$1")
    if [ ! -e "$base" ]; then mkdir -m 0700 -- "$base" || return 1; fi
    backup_delete "$1" "$2" && mkdir -m 0700 -- "$base/$2"
}

# keep_days VALUE: the days a pre-update backup, and the system disk's copy of
# data moved onto the data disk, are kept, from UPDATE_BACKUP_KEEP_DAYS: a
# whole number of days, at least backup_keep_min. The user file lies on the
# data disk when one is set up, so whoever changes the disk elsewhere can set
# it; the minimum keeps a backup for a rollback that long all the same. 7, the
# default, when VALUE is no whole number of at most six digits (the
# configuration check reports it).
backup_keep_min=3
keep_days() {
    if [[ $1 =~ ^[1-9][0-9]{0,5}$ ]]; then
        if [ "$1" -lt "$backup_keep_min" ]; then printf '%s' "$backup_keep_min"; else printf '%s' "$1"; fi
    else
        printf 7
    fi
}

# backup_fs LOCATION: the path whose file system receives a backup at
# LOCATION, as its free space is reported.
backup_fs() {
    case $1 in
        backup-disk) printf '%s' "$backup_disk_mount" ;;
        data-disk) printf '%s' "$data_disk_mount" ;;
        system-disk) printf '%s' /var ;;
        *) return 1 ;;
    esac
}

# The features of a release (/usr/lib/kamerplanter/features in its tree).
# The guard writes the pre-update backup only where the release it would
# roll back to finds it: a release without "backup-locations" (one from
# before the backup locations) looks for it on the system disk only.
release_features=/usr/lib/kamerplanter/features

# has_feature ROOT NAME: whether the release whose tree is at ROOT (empty for
# the running one) lists NAME in its features file; not when it has none.
has_feature() {
    local file=$1$release_features
    [ -f "$file" ] && grep -v '^[[:space:]]*#' -- "$file" 2>/dev/null | tr -d '[:blank:]\r' | grep -Fqx -- "$2"
}

# rollback_reach SUPPORT VERSION: why the backup goes to the system disk only,
# for the release VERSION it would roll back to; empty when that release
# finds it at every location. SUPPORT is supported (its tree lists
# backup-locations), unsupported (it does not, or has no features file), or
# unknown (its tree cannot be found, or it is not the release that was left):
# then the safe assumption is the system disk.
rollback_reach() {
    case $1 in
        supported) ;;
        unsupported) echo "the release to roll back to (${2:-unversioned}) only finds backups on the system disk" ;;
        *) echo "the release to roll back to cannot be determined, so the backup goes where every release finds it, the system disk" ;;
    esac
}

# backup_where LOCATION: LOCATION in a message.
backup_where() {
    case $1 in
        backup-disk) printf 'the backup disk kp-backup' ;;
        data-disk) printf 'the data disk kp-data' ;;
        system-disk) printf 'the system disk' ;;
        *) printf '%s' "$1" ;;
    esac
}

# backup_need BYTES: the free space a backup of volumes holding BYTES needs:
# a copy of them plus a margin of 10 % and 512 MiB (spec D5), the same at
# every location.
backup_need() { printf '%s' $(($1 * 11 / 10 + 512 * 1024 * 1024)); }

# backup_refusal LOCATION STATE DATA_ENCRYPTED PROTECTED: why LOCATION does
# not receive the backup; empty when it may. STATE is what the update tool
# found there:
#   ok          usable: the system disk; a disk set up, mounted under the
#               identity recorded for it (E8), and answering
#   not-set-up  no such disk is set up
#   missing     set up, but not mounted or not answering
#   foreign     mounted, but not under the identity recorded for it
#   moving      the data disk, while a move onto it is not verified yet: a
#               return to the system copy would leave the backup behind
# DATA_ENCRYPTED is 1 when the data disk is encrypted; PROTECTED is 1 when
# LOCATION is as well protected: an encrypted disk, or the system disk when
# the key of the data disk is kept on it. With an encrypted data disk only
# such a location is used (D8, spec/distribution-requirements/ E16); that
# rule is told first, also for a disk that is missing.
backup_refusal() {
    local where
    where=$(backup_where "$1")
    case $2 in
        not-set-up) echo "no ${where#the } is set up"; return ;;
    esac
    if [ "$3" = 1 ] && [ "$4" != 1 ]; then
        case $1 in
            system-disk) echo "the data disk kp-data is encrypted, and its key is not kept on the system disk" ;;
            *) echo "the data disk kp-data is encrypted, and $where is not" ;;
        esac
        return
    fi
    case $2 in
        ok) ;;
        missing) echo "$where is missing or not mounted" ;;
        foreign) echo "$where is mounted under another identity than the one it was set up with" ;;
        moving) echo "the move onto $where is not verified yet" ;;
        *) echo "$where is in an unknown state ($2)" ;;
    esac
}

# space_problem FREE NEED FS: why a backup that needs NEED bytes does not fit
# into the FREE bytes of the file system at FS; empty when it fits.
space_problem() {
    [ "$1" -ge "$2" ] || echo "$1 bytes free in $3, $2 needed for the pre-update backup"
}

# backup_summary LOCATION REASON [LOCATION REASON...]: the reason no location
# receives the backup, from the reasons of the locations that are set up.
# With the system disk alone it is that one reason, as without any disk.
backup_summary() {
    if [ $# -eq 2 ]; then printf '%s' "$2"; return; fi
    local out=''
    while [ $# -ge 2 ]; do
        out+="${out:+; }$(backup_where "$1"): $2"
        shift 2
    done
    printf 'no location takes the pre-update backup: %s' "$out"
}

# restore_problem LOCATION STATE RECORDED CURRENT: why a backup recorded at
# LOCATION cannot be read now; empty when it can. STATE is as for
# backup_refusal; RECORDED is the identity of the disk the backup was written
# to, CURRENT the identity of the disk set up for LOCATION now (both empty
# for the system disk). Protection does not matter for reading.
restore_problem() {
    local where
    where=$(backup_where "$1")
    [ "$1" = system-disk ] && return 0
    case $2 in
        not-set-up) echo "it is on $where ($3), which is no longer set up"; return ;;
        missing) echo "it is on $where ($3), which is missing or not mounted"; return ;;
        foreign) echo "it is on $where ($3), but the disk mounted there has another identity"; return ;;
        ok | moving) ;;
        *) echo "it is on $where, which is in an unknown state ($2)"; return ;;
    esac
    [ -n "$3" ] && [ "${3,,}" = "${4,,}" ] ||
        echo "it is on $where with the identity ${3:-unknown}, but the disk set up there now is ${4:-unknown}"
}
