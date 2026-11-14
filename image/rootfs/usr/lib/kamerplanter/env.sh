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
# which the disk service binds and every writer checks.
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
