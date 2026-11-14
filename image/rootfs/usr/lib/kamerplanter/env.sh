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
