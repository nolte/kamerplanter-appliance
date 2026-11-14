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
# the release marker of the data disk (release_version below).
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
data_disk_present() {
    local src
    mountpoint -q -- "$data_disk_mount" || return 1
    src=$(findmnt -rnvo SOURCE -M "$data_disk_mount" 2>/dev/null | tail -n1)
    [ -b "$src" ] || return 1
    dd if="$src" of=/dev/null bs=4096 count=1 iflag=direct status=none 2>/dev/null
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
data_disk_move_field() {
    local file=${2:-$data_disk_move}
    [ -f "$file" ] || return 0
    sed -n "s/^$1=//p" -- "$file" | tail -n1
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
