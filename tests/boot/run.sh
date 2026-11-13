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

DISK=$(realpath "${DISK:-.build/disk.raw}")
OUT=.build/boot
RESULTS=$OUT/results.tsv
KEY=$OUT/id_ed25519
FIRST_BOOT_TIMEOUT=1500   # includes pulling the container images
REBOOT_TIMEOUT=600
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

# start_vm <name> <firmware: bios|uefi> <disk: virtio-scsi|lsi|virtio-blk>
#          <net: virtio|e1000> <internet: on|off> <overlay>
start_vm() {
    local name=$1 fw=$2 disk=$3 net=$4 internet=$5 overlay=$6
    local args=(
        -machine pc,accel=kvm -cpu host -smp 2 -m 4096 -display none
        -serial "file:$OUT/$name.serial.log"
        -pidfile "$OUT/vm.pid" -daemonize
        # The key reaches the guest as a systemd credential; test use only.
        -smbios "type=11,value=io.systemd.credential.binary:ssh.authorized_keys.root=$PUBKEY_B64"
        -drive "if=none,id=d0,file=$overlay,format=qcow2"
    )
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
    local netdev="user,id=n0,hostfwd=tcp:127.0.0.1:18080-:8080,hostfwd=tcp:127.0.0.1:18000-:8000,hostfwd=tcp:127.0.0.1:10022-:22"
    [ "$internet" = off ] && netdev+=",restrict=on"
    case $net in
        virtio) args+=(-netdev "$netdev" -device virtio-net-pci,netdev=n0) ;;
        e1000)  args+=(-netdev "$netdev" -device e1000,netdev=n0) ;;
    esac
    rm -f "$OUT/vm.pid"
    qemu-system-x86_64 "${args[@]}"
}

vm_alive() { [ -f "$OUT/vm.pid" ] && kill -0 "$(cat "$OUT/vm.pid")" 2>/dev/null; }

# Prints the seconds until the web UI and the API both answer.
wait_up() {
    local timeout=$1 start=$SECONDS
    while ((SECONDS - start < timeout)); do
        if curl -sf -o /dev/null --max-time 5 http://127.0.0.1:18080/ &&
            curl -sf -o /dev/null --max-time 5 http://127.0.0.1:18000/api/v1/health/live; then
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
    } >"$OUT/$1.diagnose.txt" 2>&1
}

stop_vm() {
    guest systemctl poweroff >/dev/null 2>&1
    for _ in $(seq 60); do vm_alive || return 0; sleep 2; done
    kill_vm
}

kill_vm() { vm_alive && kill -9 "$(cat "$OUT/vm.pid")"; sleep 2; }

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
    } >"$OUT/run1.measure.txt" 2>&1
}

# Kill a container, expect systemd to bring it back. Needs the VM of run 1.
run_7() {
    vm_alive || { record run7 SKIP - "needs the running VM of run 1"; return; }
    local before after secs
    before=$(guest systemctl show backend.service -p NRestarts --value)
    guest podman kill backend >/dev/null
    sleep 5
    if secs=$(wait_up 300); then
        after=$(guest systemctl show backend.service -p NRestarts --value)
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
    sleep 20
    if ! guest systemctl is-failed --quiet kamerplanter-config.service ||
        guest systemctl is-active --quiet backend.service; then
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

run_2() { first_boot run2 uefi virtio-scsi virtio; stop_vm; }
run_3() { first_boot run3 bios lsi e1000; stop_vm; }
run_4() { first_boot run4 bios virtio-blk virtio; stop_vm; }

[ -f "$DISK" ] || { echo "disk image $DISK not found; run 'task disk:build' first" >&2; exit 1; }
kill_vm 2>/dev/null
: >"$RESULTS"
runs=("$@")
[ ${#runs[@]} -gt 0 ] || runs=(1 7 8 5 6 2 3 4)
for run in "${runs[@]}"; do "run_$run"; done
kill_vm 2>/dev/null
chmod -R a+rX "$OUT"
echo
column -t -s $'\t' "$RESULTS"
grep -q FAIL "$RESULTS" && exit 1
exit 0
