#!/usr/bin/env bash
# Boots the appliance disk image in QEMU under a firmware and device matrix and
# records for each run whether the web UI and the API answer. Runs inside the
# tool container (see build/in-tools.sh).
#
# Usage: tests/boot/run.sh [run ...]   (default: all runs)
#
# shellcheck disable=SC2054,SC2329
# SC2054: QEMU option values are comma-separated by design.
# SC2329: the run_* functions are dispatched by name at the bottom.
set -uo pipefail

DISK=$(realpath -m "${DISK:-.build/disk.raw}")
OUT=.build/boot
RESULTS=$OUT/results.tsv
KEY=$OUT/id_ed25519
# Seconds; CI may raise them through the environment (build/in-tools.sh
# passes them on), the defaults are what a local run uses.
FIRST_BOOT_TIMEOUT=${FIRST_BOOT_TIMEOUT:-1500}   # includes pulling the container images
REBOOT_TIMEOUT=${REBOOT_TIMEOUT:-600}
OVMF_CODE=/usr/share/edk2/ovmf/OVMF_CODE.fd
OVMF_VARS=/usr/share/edk2/ovmf/OVMF_VARS.fd

mkdir -p "$OUT"
[ -f "$KEY" ] || ssh-keygen -q -t ed25519 -N '' -f "$KEY"
PUBKEY_B64=$(base64 -w0 "$KEY.pub")

guest() {
    ssh -i "$KEY" -p 10022 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR -o ConnectTimeout=5 root@127.0.0.1 "$@"
}

record() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" | tee -a "$RESULTS"; }

new_overlay() { qemu-img create -q -f qcow2 -F raw -b "$DISK" "$1" 20G; }

# Extras for the next start_vm, empty for most runs here:
#   VM_DISKS        "SERIAL FILE [FORMAT]" per further disk (FORMAT qcow2 when
#                   left out, or raw), attached as virtio-blk with that serial,
#                   so the guest names it /dev/disk/by-id/virtio-SERIAL (at
#                   most 20 characters)
#   VM_CREDENTIALS  "NAME VALUE" per further systemd credential, as the SSH
#                   key is passed; VALUE is taken as text, or as base64 when
#                   NAME is written binary:NAME
#   VM_SMBIOS       further -smbios values, such as a NoCloud seed URL as the
#                   system serial number: "type=1,serial=ds=nocloud;s=URL"
#   VM_NIC          further properties of the network device, such as
#                   "mac=52:54:00:12:34:56" or "acpi-index=1"
#   VM_GUEST_ADDR   the guest address the ports are forwarded to; empty for the
#                   address QEMU hands out by DHCP (10.0.2.15)
#   VM_SSH_KEY      off: the SSH key is not passed as a credential, so only a
#                   key that the provisioning data supplies lets guest in
#   VM_MONITOR      a TCP port on 127.0.0.1 for QEMU's monitor (monitor below)
VM_DISKS=() VM_CREDENTIALS=() VM_SMBIOS=() VM_NIC='' VM_GUEST_ADDR='' VM_SSH_KEY=on VM_MONITOR=''

# start_vm <name> <firmware: bios|uefi> <disk: virtio-scsi|lsi|virtio-blk>
#          <net: virtio|e1000> <internet: on|off> <overlay>
start_vm() {
    local name=$1 fw=$2 disk=$3 net=$4 internet=$5 overlay=$6 extra serial file format i=1
    local args=(
        -machine pc,accel=kvm -cpu host -smp 2 -m 4096 -display none
        -serial "file:$OUT/$name.serial.log"
        -pidfile "$OUT/vm.pid" -daemonize
        -drive "if=none,id=d0,file=$overlay,format=qcow2"
    )
    # The key reaches the guest as a systemd credential; test use only.
    [ "$VM_SSH_KEY" = off ] ||
        args+=(-smbios "type=11,value=io.systemd.credential.binary:ssh.authorized_keys.root=$PUBKEY_B64")
    for extra in "${VM_SMBIOS[@]}"; do args+=(-smbios "$extra"); done
    for extra in "${VM_CREDENTIALS[@]}"; do
        case $extra in
            binary:*) extra=${extra#binary:}; args+=(-smbios "type=11,value=io.systemd.credential.binary:${extra%% *}=${extra#* }") ;;
            *) args+=(-smbios "type=11,value=io.systemd.credential:${extra%% *}=${extra#* }") ;;
        esac
    done
    for extra in "${VM_DISKS[@]}"; do
        read -r serial file format <<<"$extra"
        args+=(-drive "if=none,id=x$i,file=$file,format=${format:-qcow2}" -device "virtio-blk-pci,drive=x$i,id=xdev$i,serial=$serial")
        i=$((i + 1))
    done
    [ -z "$VM_MONITOR" ] || args+=(-monitor "tcp:127.0.0.1:$VM_MONITOR,server,nowait")
    if [ "$fw" = uefi ]; then
        cp "$OVMF_VARS" "$OUT/$name.vars.fd"
        args+=(-drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE"
               -drive "if=pflash,format=raw,file=$OUT/$name.vars.fd")
    fi
    case $disk in
        virtio-scsi) args+=(-device virtio-scsi-pci,id=scsi0 -device scsi-hd,drive=d0,bus=scsi0.0) ;;
        lsi)         args+=(-device lsi53c895a,id=scsi0 -device scsi-hd,drive=d0,bus=scsi0.0) ;;
        virtio-blk)  args+=(-device virtio-blk-pci,drive=d0) ;;
    esac
    local g=$VM_GUEST_ADDR
    local netdev="user,id=n0,hostfwd=tcp:127.0.0.1:18080-$g:8080,hostfwd=tcp:127.0.0.1:18000-$g:8000,hostfwd=tcp:127.0.0.1:10022-$g:22"
    [ "$internet" = off ] && netdev+=",restrict=on"
    case $net in
        virtio) args+=(-netdev "$netdev" -device "virtio-net-pci,netdev=n0${VM_NIC:+,$VM_NIC}") ;;
        e1000)  args+=(-netdev "$netdev" -device "e1000,netdev=n0${VM_NIC:+,$VM_NIC}") ;;
    esac
    rm -f "$OUT/vm.pid"
    qemu-system-x86_64 "${args[@]}"
}

# monitor COMMAND...: runs each command in QEMU's monitor (VM_MONITOR); fails
# when one reports an error. QEMU runs in /, so paths in them are absolute.
monitor() {
    local reply
    exec 3<>"/dev/tcp/127.0.0.1/$VM_MONITOR" || return 1
    printf '%s\n' "$@" >&3
    sleep 2
    reply=$(timeout 2 cat <&3 | tr -d '\033' | grep -ao 'Error: [^(]*')
    exec 3>&-
    [ -z "$reply" ] || { echo "$reply" >&2; return 1; }
}

vm_alive() { [ -f "$OUT/vm.pid" ] && kill -0 "$(cat "$OUT/vm.pid")" 2>/dev/null; }

# No systemd job is pending, so every unit has reached its state. HTTP answers
# alone are not enough: a unit with Notify=healthy is still starting until
# podman has marked the container healthy, and a restart issued in that window
# merges into the pending start job and restarts nothing.
settled() { [ -z "$(guest systemctl list-jobs --no-legend 2>/dev/null)" ] && guest true; }

# Prints the seconds until the web UI and the API both answer and systemd has
# no job left.
wait_up() {
    local timeout=$1 start=$SECONDS
    while ((SECONDS - start < timeout)); do
        if curl -sf -o /dev/null --max-time 5 http://127.0.0.1:18080/ &&
            curl -sf -o /dev/null --max-time 5 http://127.0.0.1:18000/api/v1/health/live &&
            settled; then
            echo $((SECONDS - start))
            return 0
        fi
        vm_alive || return 2
        sleep 5
    done
    return 1
}

diagnose() {
    {
        echo "== failed units"; guest systemctl --failed --no-pager
        echo "== containers"; guest podman ps -a
        echo "== journal errors"; guest "journalctl -b -p err --no-pager | tail -n 60"
        echo "== block devices"; guest lsblk
        echo "== boots"; guest "journalctl --list-boots --no-pager | tail -n 5"
        echo "== bootc status"; guest "bootc status --format humanreadable"
        echo "== versions"; guest "rpm -q ostree bootc systemd kernel"
        echo "== cloud-init log rotation"; guest "rpm -q logrotate; rpm -ql cloud-init | grep -i logrotate; ls /etc/logrotate.d"
        echo "== /boot now"; guest "findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS,PROPAGATION /boot; grep ' /boot ' /proc/1/mountinfo"
        echo "== previous boot: finalize and shutdown"
        guest "journalctl -b -1 --no-pager -o short-precise -u ostree-finalize-staged.service -u ostree-finalize-staged-hold.service"
        guest "journalctl -b -1 --no-pager -o short-precise | tail -n 120"
    } >"$OUT/$1.diagnose.txt" 2>&1
}

# mount_state STEP LABEL: appends what ostree-finalize-staged depends on to
# $OUT/STEP.mount-state.txt: how /boot is mounted and its units (#39).
mount_state() {
    {
        echo "== $2"
        # Read from mountinfo only: a lookup of /boot would mount it again.
        guest "grep -E ' /(boot|sysroot) ' /proc/1/mountinfo"
        guest "systemctl show -p ActiveState,SubState,FragmentPath,DropInPaths,TimeoutIdleUSec boot.automount boot.mount"
    } >>"$OUT/$1.mount-state.txt" 2>&1
}

stop_vm() {
    guest systemctl poweroff >/dev/null 2>&1
    for _ in $(seq 60); do vm_alive || return 0; sleep 2; done
    kill_vm
}

kill_vm() { vm_alive && kill -9 "$(cat "$OUT/vm.pid")"; sleep 2; }

# --- provisioning data (spec/distribution-requirements/ §L) ---

# Bounded guest command: a hung command must not stall the run.
guest_bounded() { timeout 900 ssh -o ServerAliveInterval=15 -i "$KEY" -p 10022 -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 -o IdentitiesOnly=yes root@127.0.0.1 "$@"; }

# Prints the seconds until guest answers over SSH.
wait_ssh() {
    local timeout=$1 start=$SECONDS
    while ((SECONDS - start < timeout)); do
        guest true 2>/dev/null && { echo $((SECONDS - start)); return 0; }
        vm_alive || return 2
        sleep 5
    done
    return 1
}

# Waits until cloud-init has run all its stages. "degraded done" counts as
# done: the key kamerplanter: makes cloud-init report it on every boot (L8).
cloud_init_done() {
    local rc
    guest_bounded "timeout 600 cloud-init status --wait" >/dev/null 2>&1
    rc=$?
    [ "$rc" = 0 ] || [ "$rc" = 2 ]
}

# nocloud_seed DIR HOSTNAME INSTANCE: meta-data and user-data of a NoCloud
# source in DIR. The user-data authorises the harness key for root, so with
# VM_SSH_KEY=off guest only gets in when cloud-init applied it, and asks for
# password login, which the appliance keeps refused (L5). Lines on stdin are
# appended to the user-data, network-config and the like are written by the
# caller.
nocloud_seed() {
    rm -rf "$1"; mkdir -p "$1"
    printf 'instance-id: %s\nlocal-hostname: %s\n' "$3" "$2" >"$1/meta-data"
    {
        printf '#cloud-config\nhostname: %s\nssh_pwauth: true\nssh_authorized_keys:\n  - %s\n' "$2" "$(cat "$KEY.pub")"
        [ -t 0 ] || cat
    } >"$1/user-data"
}

# nocloud_drive DIR IMAGE: a vfat drive labelled CIDATA holding the files of
# DIR, as a user would write it to a USB stick or a hypervisor attaches it.
nocloud_drive() {
    rm -f "$2"
    truncate -s 4M "$2" && mkfs.vfat -n CIDATA "$2" >/dev/null && mcopy -i "$2" "$1"/* ::/
}

# static_network ID ADDRESS [MATCH-MAC]: a network-config version 2 with a
# static IPv4 address, the gateway and DNS server of QEMU's user network, in
# one of the two forms of L6: keyed by the interface name ID, or matched by
# MAC and renamed to ID.
static_network() {
    printf 'version: 2\nethernets:\n  %s:\n' "$1"
    [ -z "${3-}" ] || printf '    match:\n      macaddress: "%s"\n    set-name: %s\n' "$3" "$1"
    printf '    dhcp4: false\n    addresses: [%s/24]\n    routes:\n      - to: default\n        via: 10.0.2.2\n    nameservers:\n      addresses: [10.0.2.3]\n' "$2"
}

# marker PREFIX: a provisioned test value, recognisable wherever it lands.
marker() { printf '%s%s' "$1" "$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"; }

# reboot_vm TIMEOUT: an orderly reboot of the running VM, the drives staying
# attached; prints the seconds until the services answer again.
reboot_vm() {
    local id now
    id=$(guest cat /proc/sys/kernel/random/boot_id)
    guest systemctl reboot >/dev/null 2>&1
    for _ in $(seq 120); do
        sleep 5
        now=$(guest cat /proc/sys/kernel/random/boot_id 2>/dev/null) && [ -n "$now" ] && [ "$now" != "$id" ] && break
    done
    [ -n "$now" ] && [ "$now" != "$id" ] || return 1
    wait_up "$1"
}

# no_copies MARKER...: the number of cloud-init's files and logs, and of the
# journal's lines, that hold one of the markers (L12, L15).
no_copies() {
    local args=() m
    for m in "$@"; do args+=(-e "$m"); done
    guest "echo \$(grep -rlF ${args[*]} /var/lib/cloud /run/cloud-init /var/log/cloud-init*.log* 2>/dev/null | wc -l) \$(journalctl -b --no-pager | grep -cF ${args[*]})"
}

# expect_rec NAME EXPECTED ACTUAL WHAT: records NAME as PASS when ACTUAL is
# EXPECTED, as FAIL with both otherwise; fails then.
expect_rec() {
    if [ "$3" = "$2" ]; then record "$1" PASS - "$4"; return 0; fi
    record "$1" FAIL - "$4: expected '$2', got '$3'"
    return 1
}

# check_provisioned NAME HOSTNAME [IFACE ADDRESS]: records whether the
# hostname, the SSH key of the user-data (VM_SSH_KEY=off, so guest only gets
# in with it), the SSH policy and, with IFACE, the static IPv4 address,
# gateway and DNS server of the provisioning data are in effect (L5, L6).
check_provisioned() {
    local name=$1 host=$2 iface=${3-} addr=${4-}
    expect_rec "$name-hostname" "$host" "$(guest hostnamectl hostname)" "hostname from the provisioning data"
    record "$name-ssh-key" PASS - "root login with the key from the user-data only"
    expect_rec "$name-ssh-policy" "passwordauthentication no|" \
        "$(guest "sshd -T 2>/dev/null | grep -i '^passwordauthentication '; echo \"|\$(getent passwd fedora cloud-user | cut -d: -f1)\"" | tr -d '\n' | tr '[:upper:]' '[:lower:]')" \
        "password login refused although the user-data asks for it; no default user"
    [ -n "$iface" ] || return 0
    expect_rec "$name-network" "$addr/24 static | 10.0.2.2 $iface | 10.0.2.3" \
        "$(guest "ip -4 -o addr show dev $iface scope global | awk '{print \$4, (/dynamic/ ? \"dynamic\" : \"static\")}' | tr '\n' ' ';
            echo \"| \$(ip -4 route show default | awk '{print \$3, \$5}') | \$(nmcli -g IP4.DNS device show $iface)\"")" \
        "$iface: static $addr/24, gateway 10.0.2.2, DNS 10.0.2.3" || diagnose "$name"
}

# first_boot <name> <firmware> <disk> <net>: fresh disk, first start with pulls.
first_boot() {
    local name=$1 overlay=$OUT/$1.qcow2 secs
    new_overlay "$overlay"
    start_vm "$name" "$2" "$3" "$4" on "$overlay" || { record "$name" FAIL - "qemu did not start"; return 1; }
    if secs=$(wait_up "$FIRST_BOOT_TIMEOUT"); then
        record "$name" PASS "${secs}s" "$2, $3, $4: first boot to web UI and API"
    else
        diagnose "$name"
        record "$name" FAIL - "$2, $3, $4: no answer within ${FIRST_BOOT_TIMEOUT}s"
        return 1
    fi
}

run_1() {
    first_boot run1 bios virtio-scsi virtio || { kill_vm; return; }
    {
        echo "== memory (MiB)"; guest free -m
        echo "== root filesystem"; guest df -h /sysroot /var
        echo "== boot time"; guest systemd-analyze
        echo "== system image"; guest "bootc status --format=json | jq '.status.booted.image'"
        echo "== containers"; guest "podman ps --format '{{.Names}} {{.Status}}'"
        echo "== image store"; guest podman system df
        echo "== update source"; guest kamerplanter-update status
    } >"$OUT/run1.measure.txt" 2>&1
    # spec/update-and-rollback/ A2: the release channel, never a local name.
    local source
    source=$(guest "bootc status --format=json | jq -r .spec.image.image")
    if [ "$source" = ghcr.io/nolte/kamerplanter-appliance:stable ]; then
        record run1-source PASS - "update source is $source"
    else
        record run1-source FAIL - "update source is $source, not the release channel"
    fi
    # spec/distribution-requirements/ L4: without provisioning data cloud-init
    # stays disabled and the address comes from DHCP.
    local ci addr
    ci=$(guest "cloud-init status 2>/dev/null | sed -n 's/^status: //p'")
    addr=$(guest "ip -4 -o addr show scope global | grep -c dynamic")
    if [ "$ci" = disabled ] && [ "$addr" -ge 1 ]; then
        record run1-noprov PASS - "no provisioning data: cloud-init disabled, address from DHCP"
    else
        record run1-noprov FAIL - "no provisioning data: cloud-init '$ci', dynamic addresses $addr"
    fi
}

# Kill a container, expect systemd to bring it back. Needs the VM of run 1.
run_7() {
    vm_alive || { record run7 SKIP - "needs the running VM of run 1"; return; }
    local before after secs
    before=$(guest systemctl show kamerplanter-backend.service -p NRestarts --value)
    guest podman kill backend >/dev/null
    sleep 5
    if secs=$(wait_up 300); then
        after=$(guest systemctl show kamerplanter-backend.service -p NRestarts --value)
        if [ "$after" -gt "$before" ]; then
            record run7 PASS "${secs}s" "killed container restarted by systemd (restarts $before -> $after)"
        else
            record run7 FAIL - "API answers but systemd counted no restart ($before -> $after)"
        fi
    else
        diagnose run7
        record run7 FAIL - "API did not come back after the container was killed"
    fi
}

# A value in the user file reaches the services; an invalid one keeps them
# stopped until it is fixed. Needs the VM of run 1.
run_8() {
    vm_alive || { record run8 SKIP - "needs the running VM of run 1"; return; }
    local file=/etc/kamerplanter/kamerplanter.env secs
    guest "echo REGISTRATION_MODE=invite_only >>$file && systemctl restart kamerplanter.target"
    if ! secs=$(wait_up "$REBOOT_TIMEOUT"); then
        diagnose run8
        record run8 FAIL - "services did not come back after setting a value in the user file"
        return
    fi
    if [ "$(guest podman exec backend printenv REGISTRATION_MODE)" != invite_only ]; then
        record run8 FAIL - "value from the user file did not reach the backend"
        return
    fi
    guest "echo FERNET_KEY=invalid >>$file; systemctl restart kamerplanter.target"
    local waited=0
    until settled || ((waited >= 120)); do sleep 5; waited=$((waited + 5)); done
    if ! guest systemctl is-failed --quiet kamerplanter-config.service ||
        guest systemctl is-active --quiet kamerplanter-backend.service; then
        diagnose run8
        record run8 FAIL - "an invalid FERNET_KEY did not keep the services stopped"
        return
    fi
    guest "sed -i '/^FERNET_KEY=invalid\$/d' $file && systemctl restart kamerplanter.target"
    if secs=$(wait_up "$REBOOT_TIMEOUT"); then
        record run8 PASS "${secs}s" "user value applied; invalid value kept the services stopped until removed"
    else
        diagnose run8
        record run8 FAIL - "services did not come back after the invalid value was removed"
    fi
}

# Orderly shutdown, then boot the same disk without internet access.
run_5() {
    [ -f "$OUT/run1.qcow2" ] || { record run5 SKIP - "needs the disk of run 1"; return; }
    vm_alive && stop_vm
    local secs
    start_vm run5 bios virtio-scsi virtio off "$OUT/run1.qcow2"
    if secs=$(wait_up "$REBOOT_TIMEOUT"); then
        record run5 PASS "${secs}s" "reboot without internet access"
    else
        diagnose run5
        record run5 FAIL - "no answer after reboot without internet access"
    fi
}

# Hard reset while running, then boot again.
run_6() {
    vm_alive || { record run6 SKIP - "needs the running VM of run 5"; return; }
    local secs
    kill_vm
    start_vm run6 bios virtio-scsi virtio off "$OUT/run1.qcow2"
    if secs=$(wait_up "$REBOOT_TIMEOUT"); then
        record run6 PASS "${secs}s" "boot after hard reset"
    else
        diagnose run6
        record run6 FAIL - "no answer after hard reset"
    fi
    stop_vm
}

# Provisioning data on a NoCloud drive (CIDATA, vfat): hostname, SSH key,
# and a static address in the form matched by MAC and renamed (L2, L5, L6);
# then the Kamerplanter settings and secrets of the provisioning data at the
# first start, a secret as a system credential, the scrub of cloud-init's
# copies, and all of it again after a reboot with the drive still attached;
# last, a boot with the drive detached keeps the settings (L9, L10, L12, L13,
# L15, L17). Before the reboot it records whether the image rotates
# cloud-init's logs (run9-logrotate, a measurement, #46) and leaves rotated
# logs holding the secret, a plain and a compressed one, for the reboot's
# scrub (run9-rotated).
run_9() {
    local VM_DISKS VM_CREDENTIALS VM_NIC=mac=52:54:00:12:34:56 VM_GUEST_ADDR=10.0.2.50 VM_SSH_KEY=off
    local seed=$OUT/run9-seed drive=$OUT/run9-cidata.img overlay=$OUT/run9.qcow2 secs
    local jwt cred url=http://kp-run9.example:8080 secrets=/etc/kamerplanter/secrets.env
    local sem=/var/lib/cloud/instance/sem/config_write_files written
    jwt=$(marker run9jwt) cred=$(marker run9salt)
    nocloud_seed "$seed" kp-run9 run9 <<EOF
kamerplanter:
  settings:
    FRONTEND_URL: "$url"
    UPDATE_WINDOW: "04:15"
  secrets:
    JWT_SECRET_KEY: "$jwt"
write_files:
  - path: /var/lib/kamerplanter/provisioning/provisioning.env
    permissions: '0600'
    content: |
      FRONTEND_URL=http://from-write-files.example
      REGISTRATION_MODE=invite_only
EOF
    static_network lan0 10.0.2.50 52:54:00:12:34:56 >"$seed/network-config"
    nocloud_drive "$seed" "$drive" || { record run9 FAIL - "the NoCloud drive could not be built"; return; }
    VM_DISKS=("cidata $drive raw")
    VM_CREDENTIALS=("kamerplanter.secret.LOG_PSEUDONYM_SALT $cred")
    new_overlay "$overlay"
    start_vm run9 bios virtio-scsi virtio on "$overlay" || { record run9 FAIL - "qemu did not start"; return; }
    if ! secs=$(wait_ssh "$REBOOT_TIMEOUT") || ! cloud_init_done; then
        diagnose run9
        record run9 FAIL - "NoCloud drive: no SSH with the user-data key at 10.0.2.50, or cloud-init did not finish"
        kill_vm; return
    fi
    record run9 PASS "${secs}s" "NoCloud drive: SSH with the user-data key at the static address"
    check_provisioned run9 kp-run9 lan0 10.0.2.50

    if ! secs=$(wait_up "$FIRST_BOOT_TIMEOUT"); then
        diagnose run9
        record run9-first-start FAIL - "no answer within ${FIRST_BOOT_TIMEOUT}s"
        kill_vm; return
    fi
    record run9-first-start PASS "${secs}s" "first start with provisioning data to web UI and API"
    expect_rec run9-settings "$url|invite_only|0|1" \
        "$(guest podman exec backend printenv FRONTEND_URL)|$(guest podman exec backend printenv REGISTRATION_MODE)|$(guest systemctl show kamerplanter-backend.service -p NRestarts --value)|$(guest "systemctl show kamerplanter-update-apply.timer -p TimersCalendar --value | grep -q '04:15:00' && echo 1")" \
        "settings at the first start without a restart: the map wins over write_files, write_files applies, UPDATE_WINDOW sets the window" ||
        diagnose run9
    # secrets-taken holds the instance id as one line of JSON.
    expect_rec run9-secrets '1|1|"run9"' \
        "$(guest "grep -cxF 'JWT_SECRET_KEY=$jwt' $secrets")|$(guest "grep -cxF 'LOG_PSEUDONYM_SALT=$cred' $secrets")|$(guest cat /var/lib/kamerplanter/provisioning/secrets-taken)" \
        "secrets from kamerplanter: -> secrets: and from the credential taken into the secrets file, the instance recorded"
    expect_rec run9-scrub "active|0 0" \
        "$(guest systemctl is-active kamerplanter-cloud-init-scrub.service)|$(no_copies "$jwt" "$cred")" \
        "no copy of a provisioned secret in cloud-init's files and logs or in the journal" ||
        diagnose run9
    # is-enabled prints "masked" and exits non-zero for a masked unit.
    expect_rec run9-guard "yes|masked" \
        "$(guest "nft list tables | grep -qx 'table inet kamerplanter_metadata' && echo yes")|$(guest "systemctl is-enabled nftables.service || true")" \
        "the metadata rules are loaded, and nftables.service, whose reload and stop would flush them, is masked"
    # Rules removed by hand come back from the check that the timer starts
    # every minute, started here at once. The guard unit and the containers,
    # which require it, keep running: their invocation ids stay the same.
    local invocations
    invocations=$(guest "systemctl show -p InvocationID --value kamerplanter-metadata-guard.service kamerplanter-backend.service | grep . | paste -sd ,")
    expect_rec run9-guard-repair "yes|yes|2|$invocations" \
        "$(guest "nft delete table inet kamerplanter_metadata && ! nft list table inet kamerplanter_metadata >/dev/null 2>&1 && echo yes")|$(guest "systemctl start kamerplanter-metadata-guard-check.service && nft list tables | grep -qx 'table inet kamerplanter_metadata' && echo yes")|$(tr , '\n' <<<"$invocations" | grep -c .)|$(guest "systemctl show -p InvocationID --value kamerplanter-metadata-guard.service kamerplanter-backend.service | grep . | paste -sd ,")" \
        "the metadata rules, removed, are loaded again by their check, without a restart of the guard unit or the containers" ||
        diagnose run9
    # A measurement, not a check: whether logrotate is installed and which
    # rule, if any, rotates cloud-init's logs.
    record run9-logrotate PASS - "cloud-init's logs: $(guest "echo \"logrotate \$(rpm -q logrotate >/dev/null 2>&1 && rpm -q logrotate || echo 'not installed'); rule: \$({ grep -l cloud-init /etc/logrotate.d/* 2>/dev/null; rpm -ql cloud-init 2>/dev/null | grep logrotate; } | sort -u | paste -sd ' ' | grep . || echo none)\"")"
    # Rotated logs that hold the secret, as a rotation would leave them: the
    # reboot's scrub replaces it in the plain one and deletes the compressed one.
    guest "cp /var/log/cloud-init.log /var/log/cloud-init.log.1 && echo 'rotated $jwt' >>/var/log/cloud-init.log.1 && { cat /var/log/cloud-init.log; echo 'rotated $jwt'; } | gzip >/var/log/cloud-init.log.2.gz && restorecon -F /var/log/cloud-init.log.1 /var/log/cloud-init.log.2.gz"
    written=$(guest stat -c %Y "$sem")

    if ! secs=$(reboot_vm "$REBOOT_TIMEOUT"); then
        diagnose run9
        record run9-reboot FAIL - "no answer after a reboot with the drive attached"
        stop_vm; return
    fi
    record run9-reboot PASS "${secs}s" "reboot with the NoCloud drive still attached"
    expect_rec run9-reboot-settings "$url|yes|$written" \
        "$(guest podman exec backend printenv FRONTEND_URL)|$([ -n "$written" ] && echo yes)|$(guest stat -c %Y "$sem")" \
        "after the reboot the settings apply and once-per-instance steps did not run again"
    expect_rec run9-reboot-secrets "1|1|1" \
        "$(guest "grep -c '^JWT_SECRET_KEY=' $secrets")|$(guest "grep -cxF 'JWT_SECRET_KEY=$jwt' $secrets")|$(guest "journalctl -b --no-pager -u kamerplanter-provisioning.service | grep -c 'were taken over on an earlier boot'")" \
        "after the reboot the secret is not taken over or staged again"
    expect_rec run9-reboot-scrub "active|0 0" \
        "$(guest systemctl is-active kamerplanter-cloud-init-scrub.service)|$(no_copies "$jwt" "$cred")" \
        "after the reboot with the drive attached no copy of a provisioned secret is left" ||
        diagnose run9
    expect_rec run9-rotated "yes|1|no" \
        "$(guest "test -f /var/log/cloud-init.log.1 && echo yes || echo no")|$(guest "grep -c 'rotated REDACTED' /var/log/cloud-init.log.1")|$(guest "test -e /var/log/cloud-init.log.2.gz && echo yes || echo no")" \
        "a rotated log is scrubbed and kept, a compressed one that holds a secret is deleted (L15)" ||
        diagnose run9

    # The drive detached, as the documentation asks: the settings stay (L10).
    stop_vm
    VM_DISKS=()
    start_vm run9-detached bios virtio-scsi virtio on "$overlay" || { record run9-detached FAIL - "qemu did not start"; return; }
    if secs=$(wait_up "$REBOOT_TIMEOUT"); then
        expect_rec run9-detached "$url|1" \
            "$(guest podman exec backend printenv FRONTEND_URL)|$(guest "grep -cxF 'JWT_SECRET_KEY=$jwt' $secrets")" \
            "with the drive detached the provisioned settings and the secret stay"
    else
        diagnose run9-detached
        record run9-detached FAIL - "no answer after a boot with the drive detached"
    fi
    stop_vm
}

# Provisioning data from a seed URL in the SMBIOS system serial number,
# served from the tool container: hostname and SSH key (L2, L5).
run_10() {
    local VM_SMBIOS=("type=1,serial=ds=nocloud;s=http://10.0.2.2:8099/") VM_SSH_KEY=off
    local seed=$OUT/run10-seed overlay=$OUT/run10.qcow2 server secs
    nocloud_seed "$seed" kp-run10 run10 </dev/null
    python3 -m http.server 8099 --bind 127.0.0.1 --directory "$seed" </dev/null >/dev/null 2>&1 &
    server=$!
    new_overlay "$overlay"
    if ! start_vm run10 bios virtio-scsi virtio on "$overlay"; then
        kill "$server"; record run10 FAIL - "qemu did not start"; return
    fi
    if secs=$(wait_ssh "$REBOOT_TIMEOUT") && cloud_init_done; then
        record run10 PASS "${secs}s" "seed URL: SSH with the user-data key"
        check_provisioned run10 kp-run10
    else
        diagnose run10
        record run10 FAIL - "seed URL: no SSH with the user-data key, or cloud-init did not finish"
    fi
    kill "$server" 2>/dev/null
    stop_vm
}

# Provisioning data on a NoCloud drive with a static address in the form
# keyed by the interface name (L6); acpi-index pins that name to eno1. The
# settings hold an invalid UPDATE_WINDOW, which keeps the services stopped
# and is named with the provisioning layer, a DATA_DISK, which is ignored with
# a message, and a FERNET_KEY, which is passed through with a warning that
# names only the key (L11, L19). No internet: nothing is pulled.
run_11() {
    local VM_DISKS VM_NIC=acpi-index=1 VM_GUEST_ADDR=10.0.2.51 VM_SSH_KEY=off
    local seed=$OUT/run11-seed drive=$OUT/run11-cidata.img overlay=$OUT/run11.qcow2 secs fernet
    fernet="$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n' | cut -c1-43)="
    nocloud_seed "$seed" kp-run11 run11 <<EOF
kamerplanter:
  settings:
    UPDATE_WINDOW: "25:00"
    DATA_DISK: /dev/disk/by-id/virtio-run11
    FERNET_KEY: "$fernet"
EOF
    static_network eno1 10.0.2.51 >"$seed/network-config"
    nocloud_drive "$seed" "$drive" || { record run11 FAIL - "the NoCloud drive could not be built"; return; }
    VM_DISKS=("cidata $drive raw")
    new_overlay "$overlay"
    start_vm run11 bios virtio-scsi virtio off "$overlay" || { record run11 FAIL - "qemu did not start"; return; }
    if ! secs=$(wait_ssh "$REBOOT_TIMEOUT") || ! cloud_init_done; then
        diagnose run11
        record run11 FAIL - "NoCloud drive: no SSH with the user-data key at 10.0.2.51, or cloud-init did not finish"
        kill_vm; return
    fi
    record run11 PASS "${secs}s" "NoCloud drive: SSH with the user-data key at the static address"
    check_provisioned run11 kp-run11 eno1 10.0.2.51

    local waited=0
    until settled || ((waited >= 300)); do sleep 5; waited=$((waited + 5)); done
    expect_rec run11-invalid "failed|stopped|1|1|1|0" \
        "$(guest systemctl is-failed kamerplanter-config.service)|$(guest "systemctl is-active --quiet kamerplanter-backend.service && echo running || echo stopped")|$(guest "journalctl -b --no-pager -u kamerplanter-config.service | grep -c 'UPDATE_WINDOW is not a time of day.*provisioning layer'")|$(guest "journalctl -b --no-pager -u kamerplanter-config.service | grep -c 'DATA_DISK in the provisioning layer.*is ignored'")|$(guest "journalctl -b --no-pager -u kamerplanter-config.service | grep -c 'warning: the secret FERNET_KEY is set in the provisioning layer'")|$(guest "journalctl -b --no-pager | grep -cF '$fernet'")" \
        "invalid provisioned UPDATE_WINDOW keeps the services stopped and names the provisioning layer; DATA_DISK ignored; FERNET_KEY warned by key only" ||
        diagnose run11
    stop_vm
}

# host_keys: the fingerprints of the guest's SSH host keys, sorted, on one line.
host_keys() {
    guest "for k in /etc/ssh/ssh_host_*_key.pub; do ssh-keygen -lf \"\$k\"; done" 2>/dev/null |
        awk '{print $2}' | sort | paste -sd ' '
}

# instance_id: the instance cloud-init set up last; the scrub keeps it (L15).
instance_id() { guest cat /var/lib/cloud/data/instance-id 2>/dev/null; }

# scrubbed: waits up to ten minutes until the scrub of cloud-init's copies has
# run on this boot; it deletes the cached datasource, obj.pkl, too, so the
# next boot reads the source again.
scrubbed() {
    local waited=0
    until guest systemctl is-active --quiet kamerplanter-cloud-init-scrub.service; do
        ((waited < 600)) || return 1
        sleep 5; waited=$((waited + 5))
    done
}

# reboot_to_ssh: an orderly reboot of the running VM; prints the seconds
# until guest answers on the new boot and cloud-init has finished, whatever
# status it reports.
reboot_to_ssh() {
    local id now='' start=$SECONDS
    id=$(guest cat /proc/sys/kernel/random/boot_id)
    guest systemctl reboot >/dev/null 2>&1
    for _ in $(seq 120); do
        sleep 5
        now=$(guest cat /proc/sys/kernel/random/boot_id 2>/dev/null) && [ -n "$now" ] && [ "$now" != "$id" ] && break
        vm_alive || return 2
    done
    [ -n "$now" ] && [ "$now" != "$id" ] || return 1
    guest_bounded "timeout 600 cloud-init status --wait" >/dev/null 2>&1
    echo $((SECONDS - start))
}

# late_evidence NAME: what a boot that did not answer over SSH in time shows
# (#33). The image writes nothing to the serial port, so the VGA console is
# saved through QEMU's monitor (VM_MONITOR) as $OUT/NAME.screen.ppm; then
# guest gets up to fifteen minutes more. If it answers late, the diagnosis
# says after how long and what held up cloud-init and sshd; if not, a second
# screen is saved. Diagnosis only: the step has failed already.
late_evidence() {
    local secs dir
    dir=$(pwd)/$OUT
    monitor "screendump $dir/$1.screen.ppm" || true
    if secs=$(wait_ssh 900); then
        diagnose "$1"
        {
            echo "== SSH answered ${secs}s after the step's timeout"
            echo "== boot timing"; guest "systemd-analyze; systemd-analyze critical-chain sshd.service"
            echo "== cloud-init"; guest "cloud-init status --long; cloud-init analyze blame | head -n 30"
            echo "== this boot: cloud-init and sshd"
            guest "journalctl -b --no-pager -o short-precise -u cloud-init-local -u cloud-init -u cloud-config -u cloud-final -u sshd -u 'sshd-keygen@*' | tail -n 200"
        } >>"$OUT/$1.diagnose.txt" 2>&1
    else
        monitor "screendump $dir/$1.screen-late.ppm" || true
        echo "== no SSH within another 900s either; see $1.screen.ppm and $1.screen-late.ppm" >"$OUT/$1.diagnose.txt"
    fi
}

# A seed URL that stops answering after the first boot (#33). The next boot
# finds no source, so cloud-init falls back to the datasource None, whose
# instance id differs, and sets up a new instance; once the URL answers
# again, it sets up the first instance anew. The SSH host keys of the first
# boot stay through both. Waits only for SSH and cloud-init.
run_12() {
    local VM_SMBIOS=("type=1,serial=ds=nocloud;s=http://10.0.2.2:8098/") VM_SSH_KEY=off VM_MONITOR=10046
    local seed=$OUT/run12-seed overlay=$OUT/run12.qcow2 server keys secs
    nocloud_seed "$seed" kp-run12 run12 </dev/null
    python3 -m http.server 8098 --bind 127.0.0.1 --directory "$seed" </dev/null >/dev/null 2>&1 &
    server=$!
    new_overlay "$overlay"
    if ! start_vm run12 bios virtio-scsi virtio on "$overlay"; then
        kill "$server"; record run12 FAIL - "qemu did not start"; return
    fi
    if ! secs=$(wait_ssh "$REBOOT_TIMEOUT") || ! cloud_init_done || ! scrubbed; then
        diagnose run12
        record run12 FAIL - "seed URL: no SSH with the user-data key, or cloud-init or the scrub did not finish"
        kill "$server"; kill_vm; return
    fi
    keys=$(host_keys)
    if [ -z "$keys" ] || ! expect_rec run12 run12 "$(instance_id)" "seed URL: instance run12 set up, SSH host keys generated ($keys)"; then
        [ -n "$keys" ] || record run12 FAIL - "seed URL: no SSH host keys after the first boot"
        diagnose run12; kill "$server"; stop_vm; return
    fi
    # Reboot only once the services are up: a reboot while the first boot
    # still pulls and starts them waits up to 25 minutes for
    # kamerplanter-arangodb to stop (vm-tests run 44891190451).
    if ! wait_up "$FIRST_BOOT_TIMEOUT" >/dev/null; then
        diagnose run12-up
        record run12-up FAIL - "seed URL: web UI and API did not answer within ${FIRST_BOOT_TIMEOUT}s"
        kill "$server"; stop_vm; return
    fi

    kill "$server"; wait "$server" 2>/dev/null
    if ! secs=$(reboot_to_ssh) || ! scrubbed; then
        late_evidence run12-fallback
        record run12-fallback FAIL - "seed URL down: no SSH after the reboot, or the scrub did not finish"
        stop_vm; return
    fi
    record run12-reboot PASS "${secs}s" "reboot with the seed URL down"
    expect_rec run12-fallback iid-datasource-none "$(instance_id)" \
        "seed URL down: cloud-init fell back to the datasource None, a new instance" || diagnose run12-fallback
    expect_rec run12-fallback-keys "$keys" "$(host_keys)" \
        "seed URL down: the SSH host keys of the first boot stay"
    if ! wait_up "$REBOOT_TIMEOUT" >/dev/null; then
        diagnose run12-fallback-up
        record run12-fallback-up FAIL - "seed URL down: web UI and API did not answer within ${REBOOT_TIMEOUT}s"
        stop_vm; return
    fi

    python3 -m http.server 8098 --bind 127.0.0.1 --directory "$seed" </dev/null >/dev/null 2>&1 &
    server=$!
    if secs=$(reboot_to_ssh); then
        record run12-back PASS "${secs}s" "reboot with the seed URL answering again"
        expect_rec run12-back-instance run12 "$(instance_id)" \
            "seed URL back: cloud-init set up instance run12 again" || diagnose run12-back
        expect_rec run12-back-keys "$keys" "$(host_keys)" \
            "seed URL back: the SSH host keys of the first boot stay"
    else
        diagnose run12-back
        record run12-back FAIL - "seed URL back: no SSH after the reboot"
    fi
    kill "$server" 2>/dev/null
    stop_vm
}

run_2() { first_boot run2 uefi virtio-scsi virtio; stop_vm; }
run_3() { first_boot run3 bios lsi e1000; stop_vm; }
run_4() { first_boot run4 bios virtio-blk virtio; stop_vm; }

# tests/boot/update.sh and tests/boot/data-disk.sh source this file for the
# helpers above.
[ "${BASH_SOURCE[0]}" = "$0" ] || return 0

[ -f "$DISK" ] || { echo "disk image $DISK not found; run 'task disk:build' first" >&2; exit 1; }
kill_vm 2>/dev/null
: >"$RESULTS"
runs=("$@")
[ ${#runs[@]} -gt 0 ] || runs=(1 7 8 5 6 2 3 4 9 10 11 12)
for run in "${runs[@]}"; do "run_$run"; done
kill_vm 2>/dev/null
# Everything but the private key becomes readable for the invoking user; the
# key is left out so that it is never world-readable, not even briefly.
find "$OUT" ! -path "$KEY" -exec chmod a+rX {} +
chmod 600 "$KEY"
echo
column -t -s $'\t' "$RESULTS"
grep -q FAIL "$RESULTS" && exit 1
exit 0
