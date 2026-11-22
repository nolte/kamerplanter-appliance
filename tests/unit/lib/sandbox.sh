# shellcheck shell=bash
# Sourced by tests/unit/*.sh: runs root scripts of the image as they ship, as
# any user, against a fake tree in a temporary directory. sandbox_install
# copies them there with every absolute path of sandbox_paths rewritten to lie
# below that directory; the commands that reach the system (bootc, systemctl,
# mountpoint and the like) are shell functions the test exports (export -f)
# to the script it runs.

sandbox_paths=(
    /usr/lib/kamerplanter/env.sh
    /usr/libexec/kamerplanter/
    /usr/share/kamerplanter/
    /etc/kamerplanter
    /etc/hostname
    /var/lib/kamerplanter
    /var/lib/containers
    /var/mnt/
    /run/kamerplanter
    /run/issue.d
    /run/cloud-init/
    /var/lib/cloud/
    /var/log/
    /run/systemd/generator/
    /usr/lib/systemd/system-generators/
    /sysroot/
)

# sandbox_install ROOT IMAGE FILE...: copies each FILE, an absolute path in
# the image's tree IMAGE, to ROOT/FILE, executable, with its paths rewritten.
# The features of the release (/usr/lib/kamerplanter/features) keep their
# path: a deployment's tree below ROOT/sysroot is looked into with it.
sandbox_install() {
    local root=$1 image=$2 file p rules=()
    shift 2
    for p in "${sandbox_paths[@]}"; do rules+=(-e "s|$p|$root$p|g"); done
    for file in "$@"; do
        mkdir -p "$root${file%/*}"
        sed "${rules[@]}" "$image$file" >"$root$file"
        chmod 0755 "$root$file"
    done
}

# sandbox_mounts: defines mountpoint and findmnt, for the subshell that calls
# it and, exported, for the scripts it runs, as a data disk in place shows
# them: with MOUNTED set, every path is a mount point, and each location of
# data_disk_places is bound from the directory of its name on the disk
# (bound_from in /usr/lib/kamerplanter/env.sh). The disk and the locations
# must lie on one file system, as they do below one temporary directory.
sandbox_mounts() {
    # shellcheck disable=SC2329 # called by the scripts it is exported to
    mountpoint() { [ -n "${MOUNTED-}" ]; }
    # shellcheck disable=SC2329 # called by the scripts it is exported to
    findmnt() {
        case " $* " in *" FSROOT "*) ;; *) return 0 ;; esac
        case ${!#} in
            */etc/kamerplanter) echo /etc ;;
            */pinned) echo /pinned ;;
            */volumes/*) echo "/volumes/${!###*/}" ;;
        esac
    }
    export MOUNTED
    export -f mountpoint findmnt
}
