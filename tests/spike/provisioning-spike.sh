#!/usr/bin/env bash
# P1 feasibility spike for issue #17 (provisioning data); runs on the
# exp/provisioning-spike branch only. Expects .build/disk.raw written from the
# cloud-init variant (tests/spike/Containerfile.cloud-init).
# shellcheck disable=SC2317,SC2329,SC2054,SC2015
# SC2317/SC2329: run.sh ends in exit for direct runs; sourced, it returns early.
# SC2054: QEMU option values contain commas. SC2015: report lines use a && b || c on purpose.
set -uo pipefail
export DISK=.build/disk.raw
source tests/boot/run.sh
P=.build/spike
rm -rf "$P"; mkdir -p "$P"
LOG=$P/log.txt
say() { echo "### $*" | tee -a "$LOG"; }
run() {  # bounded: a hung guest command must not stall the spike
    timeout 900 ssh -i "$KEY" -p 10022 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR -o ConnectTimeout=5 -o ServerAliveInterval=15 root@127.0.0.1 bash -s >>"$LOG" 2>&1 ||
        echo "### run ended with $?" >>"$LOG"
}
EXTRA=()
qemu-system-x86_64() { command qemu-system-x86_64 "$@" "${EXTRA[@]}"; }
up() { wait_up 1500 >/dev/null || { say "NOT UP"; diagnose spike; cp "$OUT"/spike.diagnose.txt "$P/" 2>/dev/null; }; }
reboot_vm() {
    local id n; id=$(guest cat /proc/sys/kernel/random/boot_id)
    guest systemctl reboot >/dev/null 2>&1
    for _ in $(seq 120); do sleep 5; n=$(guest cat /proc/sys/kernel/random/boot_id 2>/dev/null) && [ -n "$n" ] && [ "$n" != "$id" ] && break; done
    up
}

dnf -y -q install xorriso dosfstools mtools >/dev/null 2>&1 || say "tool install failed"
ssh-keygen -q -t ed25519 -N '' -f "$P/userdata_key"
UD_KEY=$(cat "$P/userdata_key.pub")
MARK=MARKERSECRET0123456789abcdef0123456789abcd
# Runs to execute; the first spike run completed C1, Q1 and A.
RUNS=${RUNS:-C2 A B D}
want() { [[ " $RUNS " == *" $1 "* ]]; }

seed() {  # seed DIR HOSTNAME INSTANCE [static]
    mkdir -p "$1"
    printf 'instance-id: %s\nlocal-hostname: %s\n' "$3" "$2" >"$1/meta-data"
    cat >"$1/user-data" <<EOF
#cloud-config
hostname: $2
ssh_authorized_keys:
  - $UD_KEY
kamerplanter:
  settings:
    FRONTEND_URL: http://$2:8080
  secrets:
    JWT_SECRET_KEY: $MARK
write_files:
  - path: /etc/kamerplanter/provisioning.env
    permissions: '0600'
    content: |
      CORS_ORIGINS=["http://$2:8080"]
EOF
    if [ "${4-}" = static ]; then
        cat >"$1/network-config" <<'EOF'
version: 2
ethernets:
  primary:
    match:
      name: "e*"
    dhcp4: false
    addresses: [10.0.2.15/24, 10.0.2.50/24]  # .15 keeps the QEMU port forward working
    routes:
      - to: default
        via: 10.0.2.2
    nameservers:
      addresses: [10.0.2.3]
EOF
    fi
}

report_common() {
    run <<'EOS'
echo "hostname: $(hostnamectl --static)"
echo "cloud-init: $(cloud-init --version 2>&1)"
cloud-init status --long 2>&1 | head -20
echo "--- ds-identify"; cat /run/cloud-init/ds-identify.log 2>/dev/null | grep -iE 'datasource|dslist|found|mode' | tail -6
echo "--- schema"; cloud-init schema --system 2>&1 | tail -5
echo "--- addresses"; ip -4 -o addr show scope global; ip route | head -3
nmcli -g NAME,TYPE,DEVICE con show --active 2>/dev/null; for c in $(nmcli -g UUID con show --active 2>/dev/null); do echo "$c method=$(nmcli -g ipv4.method con show "$c")"; done
echo "--- NM keyfiles"; ls -l /etc/NetworkManager/system-connections/ 2>&1; cat /etc/NetworkManager/system-connections/* 2>/dev/null | grep -vE "^(uuid|psk)"; nmcli -f NAME,UUID,DEVICE,ACTIVE,AUTOCONNECT-PRIORITY con show; journalctl -b -o short-monotonic --no-pager -u NetworkManager -u cloud-init-local -u cloud-init-network 2>/dev/null | grep -iE "Started|activat|cloud-init primary|Wired connection" | head -15
echo "--- cloud-init network log"; grep -iE "network|render|netplan|NetworkManager" /var/log/cloud-init.log 2>/dev/null | grep -viE "url|metadata" | tail -12
echo "--- root authorized_keys"; wc -l /root/.ssh/authorized_keys 2>&1; grep -c spike-userdata /root/.ssh/authorized_keys 2>/dev/null || true
echo "--- default user"; getent passwd fedora cloud-user 2>&1 | head
echo "--- write_files target"; ls -l /etc/kamerplanter/provisioning.env 2>&1
echo "--- boot time"; systemd-analyze 2>&1 | head -2
EOS
}

########## Run C: no provisioning source, then seed files on the disk
if want C2; then
say "C1 no source (DHCP, cloud-init idle?)"
new_overlay "$P/c.qcow2"
start_vm spikeC bios virtio-scsi virtio off "$P/c.qcow2"
up
report_common
if want Q1; then
say "Q1 image: packages, config, units"
run <<'EOS'
comm -13 /usr/share/kamerplanter/spike-rpms-before /usr/share/kamerplanter/spike-rpms-after | tr '\n' ' '; echo
rpm -q cloud-init python3 nftables firewalld 2>&1
du -sh /usr/lib/python3*/site-packages/cloudinit 2>/dev/null
grep -nE '^(users|disable_root|ssh_pwauth|default_user|  - default)|^ *name: |^cloud_(init|config|final)_modules' /etc/cloud/cloud.cfg | head -20
cat /etc/cloud/cloud.cfg.d/*.cfg
systemctl list-unit-files 'cloud*' --no-legend
for u in cloud-init-main cloud-init-local cloud-init-network cloud-init cloud-config cloud-final; do systemctl cat $u.service >/dev/null 2>&1 && echo "$u: $(systemctl show -p After -p Before -p WantedBy --value $u.service | tr '\n' ' ' | cut -c1-400)"; done
systemctl is-enabled nm-cloud-setup.service nm-cloud-setup.timer 2>&1
echo "--- ordering vs kamerplanter-config"; systemd-analyze critical-chain kamerplanter-config.service 2>&1 | head -12
systemd-analyze verify cloud-init.service cloud-config.service kamerplanter-config.service 2>&1 | head -5
echo "--- hetzner/openstack detection in ds-identify"; grep -nE 'dscheck_Hetzner|dscheck_OpenStack' -A8 /usr/lib/cloud-init/ds-identify 2>/dev/null | grep -iE 'hetzner|openstack|dmi|product|vendor|chassis' | head -12
EOS
fi
say "C2 seed files under /var/lib/cloud/seed/nocloud, clean, reboot"
seed "$P/seed-c" kp-spike-c spike-c
guest "mkdir -p /var/lib/cloud/seed/nocloud && cat >/var/lib/cloud/seed/nocloud/meta-data" <"$P/seed-c/meta-data"
guest "cat >/var/lib/cloud/seed/nocloud/user-data" <"$P/seed-c/user-data"
guest "cloud-init clean --logs >/dev/null 2>&1; true"
say "C2 seed dir before reboot"; guest "ls -la /var/lib/cloud/seed/nocloud/; findmnt -no SOURCE,FSTYPE,OPTIONS /var/lib/cloud" >>"$LOG" 2>&1
reboot_vm
say "C2 seed dir after reboot, full ds-identify log"; guest "ls -la /var/lib/cloud/seed/nocloud/; cat /run/cloud-init/ds-identify.log; systemctl show -p ActiveEnterTimestampMonotonic var.mount; findmnt -no SOURCE,FSROOT /var" >>"$LOG" 2>&1
say "C3 same seed, datasource_list NoCloud only"; guest "printf 'datasource_list: [ NoCloud, None ]\\n' >/etc/cloud/cloud.cfg.d/90-spike-only-nocloud.cfg; cloud-init clean --logs >/dev/null 2>&1; true"
reboot_vm
guest "grep -E 'found|Found|single|returning' /run/cloud-init/ds-identify.log; cloud-init status --long | head -5" >>"$LOG" 2>&1
report_common
stop_vm
fi

########## Run A: CIDATA ISO with static IPv4
if want A; then
say "A1 NoCloud ISO (CIDATA), static IPv4 10.0.2.15+.50 (manual, not dynamic), user-data key, kamerplanter key, secret marker"
seed "$P/seed-a" kp-spike-a spike-a static
xorriso -as mkisofs -quiet -V CIDATA -J -r -o "$P/seed-a.iso" "$P/seed-a" >/dev/null 2>&1 || say "xorriso failed"
EXTRA=(-drive "file=$P/seed-a.iso,media=cdrom,readonly=on")
new_overlay "$P/a.qcow2"
start_vm spikeA bios virtio-scsi virtio off "$P/a.qcow2"
up
report_common
say "A2 ssh with the key that is only in the user-data"
ssh -i "$P/userdata_key" -p 10022 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 -o IdentitiesOnly=yes root@127.0.0.1 true \
    && say "A2 user-data key works for root" || say "A2 user-data key REFUSED for root"
say "A3 where does the secret marker persist"
run <<EOS
grep -rlF $MARK /var/lib/cloud /run/cloud-init /var/log 2>/dev/null
echo "journal hits: \$(journalctl -b --no-pager | grep -cF $MARK)"
echo "--- query userdata works?"; cloud-init query userdata 2>/dev/null | grep -c kamerplanter
python3 -c 'import yaml; print("pyyaml ok")' 2>&1
ls -la /var/lib/cloud/instance/ 2>&1 | head -20
EOS
say "A4 scrub, reboot with the drive attached, marker again?"
run <<EOS
for f in \$(grep -rlF $MARK /var/lib/cloud /run/cloud-init /var/log 2>/dev/null); do rm -f "\$f"; done
grep -rlF $MARK /var/lib/cloud /run/cloud-init /var/log 2>/dev/null | wc -l
EOS
reboot_vm
run <<EOS
echo "after reboot, files with marker:"; grep -rlF $MARK /var/lib/cloud /run/cloud-init /var/log 2>/dev/null
cloud-init status --long 2>&1 | grep -E 'status|boot_status|detail' | head -4
EOS
say "Q5 metadata restriction with a local double on 169.254.169.254"
run <<'EOS'
rpm -q nftables 2>&1
ip addr add 169.254.169.254/32 dev lo
mkdir -p /tmp/md && echo ok >/tmp/md/index.html
(cd /tmp/md && setsid nohup python3 -m http.server 80 --bind 169.254.169.254 </dev/null >/dev/null 2>&1 &)
sleep 2
curl -s -m 3 -o /dev/null -w 'before: root %{http_code}\n' http://169.254.169.254/
nft -f - <<'NFT' && echo "nft rules loaded"
table inet kp_metadata {
  chain output { type filter hook output priority 0; ip daddr 169.254.169.254 meta skuid != 0 drop; }
  chain input { type filter hook input priority 0; ip daddr 169.254.169.254 iifname != "lo" drop; }
  chain forward { type filter hook forward priority 0; ip daddr 169.254.169.254 drop; }
}
NFT
curl -s -m 3 -o /dev/null -w 'after: root %{http_code}\n' http://169.254.169.254/
runuser -u nobody -- curl -s -m 3 -o /dev/null -w 'after: nobody %{http_code}\n' http://169.254.169.254/ || echo "after: nobody blocked"
timeout 30 podman --storage-opt=additionalimagestore=/usr/lib/bootc/storage exec backend python3 -c "import urllib.request;print('after: container', urllib.request.urlopen('http://169.254.169.254/',timeout=3).status)" </dev/null >/tmp/md/exec.out 2>&1; tail -1 /tmp/md/exec.out
EOS
stop_vm
fi

########## Run B: seed URL via SMBIOS serial, plus a systemd credential
if want B; then
say "B1 seed URL via SMBIOS serial, credential kamerplanter.secret.JWT_SECRET_KEY"
seed "$P/seed-b" kp-spike-b spike-b
(cd "$P/seed-b" && setsid nohup python3 -m http.server 8099 --bind 127.0.0.1 </dev/null >/dev/null 2>&1 &)
sleep 1
EXTRA=(-smbios "type=1,serial=ds=nocloud;s=http://10.0.2.2:8099/"
       -smbios "type=11,value=io.systemd.credential:kamerplanter.secret.JWT_SECRET_KEY=CREDMARKER0123456789abcdef0123456789abcd")
new_overlay "$P/b.qcow2"
start_vm spikeB bios virtio-scsi virtio on "$P/b.qcow2"
up
report_common
run <<'EOS'
echo "--- credentials"; systemd-creds --system list 2>&1 | grep -i kamerplanter
systemd-run --wait --pipe -q -p ImportCredential='kamerplanter.secret.*' sh -c 'ls "$CREDENTIALS_DIRECTORY"; wc -c "$CREDENTIALS_DIRECTORY"/*' 2>&1
echo "journal hits for credential value: $(journalctl -b --no-pager | grep -c CREDMARKER)"
EOS
stop_vm
fi

########## Run D: vfat CIDATA drive
if want D; then
say "D1 NoCloud vfat drive (CIDATA)"
seed "$P/seed-d" kp-spike-d spike-d
truncate -s 4M "$P/seed-d.img" && mkfs.vfat -n CIDATA "$P/seed-d.img" >/dev/null && mcopy -i "$P/seed-d.img" "$P/seed-d/user-data" "$P/seed-d/meta-data" ::/ || say "vfat build failed"
EXTRA=(-drive "if=none,id=d9,file=$P/seed-d.img,format=raw" -device scsi-hd,drive=d9,bus=scsi0.0)
new_overlay "$P/d.qcow2"
start_vm spikeD bios virtio-scsi virtio off "$P/d.qcow2"
up
report_common
stop_vm
fi
say "DONE"
chmod -R a+rX .build/spike
