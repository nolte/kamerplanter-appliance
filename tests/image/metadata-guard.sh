#!/usr/bin/env bash
# Tries the metadata rules of the system image (spec/distribution-requirements/
# L16, image/rootfs/usr/share/kamerplanter/nftables/metadata-guard.nft) with
# the image's own nft, in a container without a network of its own
# (--network none): the rules, the addresses and the network namespaces exist
# only there and go with it. The host's firewall is never touched.
#
# Inside, three network namespaces stand for the appliance (the container's
# own), a Podman container on a bridge network ("ctr", routed through the
# appliance like netavark's containers) and the metadata service ("md",
# answering on 169.254.169.254, on another link-local address, 169.254.10.10,
# and, as a control, on 192.0.2.10; over IPv6 on fe80::a9fe:a9fe, as
# OpenStack does). A table that accepts everything, as Podman's netavark keeps
# its own, is loaded first. The checks run once without the rules, so that
# they can fail, and once with them, loaded twice as on a restart of the unit.
#
# Before that, the image's Quadlet generator translates the shipped units, and
# the podman command lines it writes are checked as Podman runs them: every
# container joins kamerplanter.network and nothing else, and none can enter
# the host's network namespace (privileged, the host's PID namespace, a
# capability to join or change namespaces, a mount of the host's /proc, /run,
# /etc, /var or /, its /proc/sys made writable or its confinement lifted),
# which would let it send as uid 0 past the output rule. The same check
# runs on planted units, one way out each, so that it can fail.
# tests/unit/scrub.sh checks the units' source on every pull request.
#
# Runs in the tool container, after `task image:build`:
#   build/in-tools.sh tests/image/metadata-guard.sh [IMAGE]
set -euo pipefail

image=${1:-${IMAGE_REF:-localhost/kamerplanter-appliance:poc}}

# Reads the output of `podman-system-generator --dryrun` and prints
# "container UNIT" for each podman run or create it checked and
# "refused UNIT: WHY" for each way out of the bridge network or into the
# host's network namespace. argv[1]: the network every container joins.
# Options are read as Podman's parser reads them (--opt VALUE, --opt=VALUE,
# -vVALUE, -tv VALUE); an option after the image, in the container's own
# command, is read as one too, which can only refuse more. A $ is refused:
# systemd would expand it from the unit's environment; so is a specifier but
# %t in a host path (%E is /etc, %S /var/lib), which systemd expands too.
IFS= read -r -d '' quadlet_check <<'PY' || true
import posixpath
import re
import shlex
import sys

network = sys.argv[1]
caps = {"all", "sys_admin", "net_admin", "sys_ptrace", "sys_module",
        "dac_read_search"}
verbs = {"run", "create", "kube", "pod", "build", "network", "volume",
         "rm", "stop", "start", "image", "pull", "secret"}
valued = {"--network", "--net", "--pid", "--pod", "--cap-add", "--volume",
          "--mount", "--module", "--driver", "--opt", "--rootfs",
          "--hooks-dir", "--security-opt"}
# --security-opt values that make /proc/sys writable or lift the confinement
unconfined = ("unmask=", "systempaths=unconfined", "seccomp=", "label=disable",
              "label=type:", "apparmor=unconfined")


def host(src):
    # True for a host path that leads into the host's namespaces.
    if src.startswith("%t"):
        src = "/run" + src[2:]
    if re.search(r"%[^%]", src.replace("%%", "")):
        return True  # another specifier: systemd expands it to a host path
    if not src.startswith("/"):
        return False
    path = "/" + posixpath.normpath(src).lstrip("/")
    if posixpath.basename(path) in ("podman.sock", "docker.sock"):
        return True
    return path in ("/", "/var", "/var/lib") or any(
        path == d or path.startswith(d + "/")
        for d in ("/proc", "/run", "/var/run", "/etc", "/var/lib/containers",
                  "/root", "/var/roothome", "/sysroot", "/ostree", "/boot"))


def options(args, short):
    # (name, value) per option; short maps a one-letter option to its name.
    i = 0
    while i < len(args):
        a = args[i]
        name = value = None
        if a.startswith("--") and len(a) > 2:
            name, eq, value = a.partition("=")
            if not eq:
                value = None
                if name in valued and i + 1 < len(args):
                    i += 1
                    value = args[i]
        elif len(a) >= 2 and a[0] == "-" and a[1] != "-":
            # one-letter options may share a dash: -tv/proc is -t -v /proc
            for j, c in enumerate(a[1:], 1):
                if c in short:
                    name, value = short[c], a[j + 1:].removeprefix("=")
                    if not value and i + 1 < len(args):
                        i += 1
                        value = args[i]
                    break
                if not c.isalpha():
                    break
        if name:
            yield name, value
        i += 1


units = re.split(r"^---(.+)---$", sys.stdin.read(), flags=re.M)
for unit, body in zip(units[1::2], units[2::2]):
    for line in re.sub(r"\\\n", " ", body).splitlines():
        m = re.match(r"\s*Exec\w*=\s*[-@:+!|]*(\S+)(.*)", line)
        if not m or posixpath.basename(m.group(1)) != "podman":
            continue
        args = shlex.split(m.group(2))
        at = next((i for i, a in enumerate(args) if a in verbs), len(args))
        verb = args[at] if at < len(args) else ""
        rest = args[at + 1:]

        def refuse(why):
            print(f"refused {unit}: {why}")

        if any("$" in a for a in args):
            refuse("a $ that systemd expands, so what runs is not visible here")
        for name, _ in options(args[:at], {}):
            if name in ("--module", "--hooks-dir"):
                refuse(f"{name}, which changes what every container gets")
        if verb in ("kube", "pod", "build"):
            refuse(f"podman {verb}, which carries a network of its own")
        elif verb == "network" and rest[:1] == ["create"]:
            for name, value in options(rest, {"d": "--driver"}):
                if name == "--driver" and value != "bridge":
                    refuse(f"a network with the driver {value}")
        elif verb == "volume" and rest[:1] == ["create"]:
            for name, value in options(rest, {"o": "--opt"}):
                if name == "--opt" and value and value.startswith("device=") \
                        and host(value[len("device="):]):
                    refuse(f"a volume of the host's {value[len('device='):]}")
        elif verb in ("run", "create"):
            print(f"container {unit}")
            nets = []
            for name, value in options(rest, {"v": "--volume"}):
                if name in ("--network", "--net"):
                    nets.append(value)
                elif name == "--privileged" and value != "false":
                    refuse("privileged")
                elif name in ("--pid", "--pod", "--rootfs"):
                    refuse(f"{name} {value}")
                elif name == "--security-opt" and \
                        (value or "").lower().startswith(unconfined):
                    refuse(f"{name} {value}")
                elif name == "--cap-add":
                    for cap in (value or "").lower().split(","):
                        if cap.removeprefix("cap_") in caps:
                            refuse(f"the capability {cap}")
                elif name == "--volume" and host((value or "").split(":")[0]):
                    refuse(f"a volume {value}")
                elif name == "--mount":
                    fields = dict(f.partition("=")[::2]
                                  for f in (value or "").split(","))
                    src = fields.get("source", fields.get("src", ""))
                    if host(src):
                        refuse(f"a mount {value}")
            if nets != [network]:
                refuse(f"the networks {nets}, not only {network}")
PY

# shellcheck disable=SC2016 # expanded inside the container
inner='
set -uo pipefail
rules=/usr/share/kamerplanter/nftables/metadata-guard.nft
failures=0
expect() {
    if [ "$2" = "$3" ]; then printf "ok    %s\n" "$1"
    else printf "FAIL  %s\n      expected: %s\n      actual:   %s\n" "$1" "$2" "$3"; failures=$((failures + 1)); fi
}
# get [WHO] ADDRESS: "yes" when ADDRESS answers over HTTP within 3 s.
get() {
    local prefix=()
    case $1 in
        root) prefix=() ;;
        nobody) prefix=(setpriv --reuid 65534 --regid 65534 --clear-groups) ;;
        ctr) prefix=(ip netns exec ctr) ;;
    esac
    if "${prefix[@]}" curl -gs -o /dev/null --max-time 3 "http://$2/" 2>/dev/null; then echo yes; else echo no; fi
}

expect "the rules pass nft'"'"'s check" 0 "$(nft -c -f "$rules" >/dev/null 2>&1; echo $?)"

# --- the generated container units ---
generator=/usr/lib/systemd/system-generators/podman-system-generator
quadlets=/usr/share/containers/systemd
network=$(sed -n "s/^NetworkName=//p" "$quadlets/kamerplanter.network")
# generated [DIR]: the generator'"'"'s exit status and the findings on its
# output for the image'"'"'s units, or for those in DIR; its errors go to the log.
generated() {
    local out rc
    out=$(if [ $# -gt 0 ]; then QUADLET_UNIT_DIRS=$1 "$generator" --dryrun; else "$generator" --dryrun; fi)
    rc=$?
    echo "exit $rc"
    python3 -c "$QUADLET_CHECK" "$network" <<<"$out"
}
refused() { sed -nE "s/^refused ([^:]*)\.service: .*/\1/p" | LC_ALL=C sort -u | paste -sd ";" | grep . || echo none; }
shipped=$(find "$quadlets" -maxdepth 1 -name "kamerplanter-*.container" | wc -l)
found=$(generated)
expect "quadlets: the generator translates the shipped units, and every container unit is checked" "kamerplanter|exit 0|yes|$shipped" \
    "$network|$(grep "^exit " <<<"$found")|$([ "$shipped" -gt 0 ] && echo yes)|$(grep -c "^container " <<<"$found")"
expect "quadlets: every container joins only kamerplanter.network and none can enter the host'"'"'s network namespace" none \
    "$(grep "^refused " <<<"$found" | sed "s/^refused //" | paste -sd ";" | grep . || echo none)"
planted=$(mktemp -d)
cp "$quadlets/kamerplanter.network" "$planted/"
# plant NAME LINE...: a container unit with these lines.
plant() { local f=$planted/$1.container; shift; printf "[Container]\nImage=example.org/i:1\n" >"$f"; printf "%s\n" "$@" >>"$f"; }
plant privileged Network=kamerplanter.network PodmanArgs=--privileged
plant pid Network=kamerplanter.network PodmanArgs=--pid=host
plant cap Network=kamerplanter.network "AddCapability=CHOWN NET_ADMIN"
plant sys-admin Network=kamerplanter.network AddCapability=SYS_ADMIN
plant cluster Network=kamerplanter.network PodmanArgs=-tv/proc:/hp
printf "[Container]\nRootfs=/\nNetwork=kamerplanter.network\n" >"$planted/rootfs.container"
plant etc Network=kamerplanter.network Volume=/etc:/host-etc
plant proc Network=kamerplanter.network Volume=/proc:/host/proc:ro
plant netns Network=kamerplanter.network Mount=type=bind,source=/run/netns,destination=/netns
plant socket Network=kamerplanter.network Volume=%t/podman/podman.sock:/sock
plant module Network=kamerplanter.network GlobalArgs=--module=/etc/containers/host.conf
plant host Network=host
plant net2 Network=kamerplanter.network PodmanArgs=--network=host
plant specifier Network=kamerplanter.network Volume=%E:/host-etc
plant parent Network=kamerplanter.network Volume=/var/lib:/l
plant sysroot Network=kamerplanter.network Mount=type=bind,source=/sysroot,destination=/s
plant unmask Network=kamerplanter.network Unmask=ALL
plant seccomp Network=kamerplanter.network PodmanArgs=--security-opt=seccomp=unconfined
plant harmless Network=kamerplanter.network "AddCapability=CHOWN NET_BIND_SERVICE" Volume=/var/lib/kamerplanter/x:/x:ro,z
printf "[Pod]\n" >"$planted/bad.pod"
printf "[Network]\nDriver=macvlan\n" >"$planted/bad.network"
printf "[Volume]\nDevice=/run/netns\nType=none\nOptions=bind\n" >"$planted/bad.volume"
found=$(generated "$planted")
expect "quadlets: the check refuses each planted way out, and passes the harmless unit" \
    "exit 0|19|bad-network;bad-pod;bad-volume;cap;cluster;etc;host;module;net2;netns;parent;pid;privileged;proc;rootfs;seccomp;socket;specifier;sys-admin;sysroot;unmask" \
    "$(grep "^exit " <<<"$found")|$(grep -c "^container " <<<"$found")|$(refused <<<"$found")"
rm -rf "$planted"

ip link set lo up
mount -t tmpfs tmpfs /run/netns 2>/dev/null || { mkdir -p /run/netns && mount -t tmpfs tmpfs /run/netns; }
ip netns add ctr
ip netns add md
ip link add br-ctr type veth peer name eth0 netns ctr
ip link add br-md type veth peer name eth0 netns md
ip addr add 10.88.0.1/24 dev br-ctr
ip addr add 192.0.2.1/30 dev br-md
ip link set br-ctr up
ip link set br-md up
ip route add 169.254.169.254/32 via 192.0.2.2 dev br-md
ip route add 169.254.10.10/32 via 192.0.2.2 dev br-md
ip route add 192.0.2.10/32 via 192.0.2.2 dev br-md
ip netns exec ctr ip link set lo up
ip netns exec ctr ip addr add 10.88.0.2/24 dev eth0
ip netns exec ctr ip link set eth0 up
ip netns exec ctr ip route add default via 10.88.0.1
ip netns exec md ip link set lo up
ip netns exec md ip addr add 192.0.2.2/30 dev eth0
ip netns exec md ip addr add 169.254.169.254/32 dev lo
ip netns exec md ip addr add 169.254.10.10/32 dev lo
ip netns exec md ip addr add 192.0.2.10/32 dev lo
ip netns exec md ip link set eth0 up
ip netns exec md ip route add 10.88.0.0/24 via 192.0.2.1
echo 1 >/proc/sys/net/ipv4/ip_forward
# IPv6: the metadata service answers on fe80::a9fe:a9fe on the appliance'"'"'s
# link to it, as OpenStack'"'"'s does. Linux routes no packet to a link-local
# address onto another link: one that the container sends to the appliance
# goes back out the link it came in on, so the address is out of a
# container'"'"'s reach anyway. The forward rule is a second line; the container
# sends there through the appliance, so that the packet passes the forward
# hook and the rule can be seen to refuse it. nodad: the addresses are usable
# at once.
ip -6 addr add fd00:88::1/64 dev br-ctr nodad
ip netns exec ctr ip -6 addr add fd00:88::2/64 dev eth0 nodad
ip netns exec ctr ip -6 route add fe80::a9fe:a9fe/128 via fd00:88::1 dev eth0 src fd00:88::2
ip netns exec md ip -6 addr add fe80::a9fe:a9fe/64 dev eth0 nodad
echo 1 >/proc/sys/net/ipv6/conf/all/forwarding
md6="[fe80::a9fe:a9fe%25br-md]"
ctr6="[fe80::a9fe:a9fe%25eth0]"
# packets TABLE CHAIN: the packets counted by the rule of CHAIN for the IPv6
# metadata address.
packets() { nft list chain inet "$1" "$2" | grep -F "ip6 daddr fe80::a9fe:a9fe" | grep -oE "packets [0-9]+" | cut -d" " -f2; }
# "::" listens on IPv4 as well.
ip netns exec md python3 -m http.server --bind :: 80 >/dev/null 2>&1 &
server=$!
for _ in $(seq 50); do [ "$(get root 192.0.2.10)" = yes ] && break; sleep 0.2; done
# The appliance'"'"'s own link-local address on br-md takes a moment.
for _ in $(seq 50); do [ "$(get root "$md6")" = yes ] && break; sleep 0.2; done

# A table of another owner that accepts everything, as netavark keeps its own.
nft -f - <<EOF
table inet netavark {
    chain forward { type filter hook forward priority filter; policy accept; ip daddr 169.254.169.254 accept; ip6 daddr fe80::a9fe:a9fe counter accept; }
    chain output { type filter hook output priority filter; policy accept; ip daddr 169.254.169.254 accept; }
}
EOF

expect "without the rules: root, another user and a container reach the metadata service" "yes|yes|yes" \
    "$(get root 169.254.169.254)|$(get nobody 169.254.169.254)|$(get ctr 169.254.169.254)"
expect "without the rules: a container reaches another link-local address" yes "$(get ctr 169.254.10.10)"
expect "without the rules: root and another user reach the IPv6 metadata address" "yes|yes" \
    "$(get root "$md6")|$(get nobody "$md6")"
get ctr "$ctr6" >/dev/null
expect "without the rules: a container'"'"'s packet to the IPv6 metadata address passes the forward hook" yes \
    "$([ "$(packets netavark forward)" -gt 0 ] 2>/dev/null && echo yes)"

nft -f "$rules" && nft -f "$rules"
expect "the rules load, also a second time, as one table beside the other" "yes|1|yes" \
    "$(nft list tables | grep -qx "table inet kamerplanter_metadata" && echo yes)|$(nft list tables | grep -cx "table inet kamerplanter_metadata")|$(nft list tables | grep -qx "table inet netavark" && echo yes)"
expect "with the rules: root reaches the metadata service" yes "$(get root 169.254.169.254)"
expect "with the rules: another user does not" no "$(get nobody 169.254.169.254)"
expect "with the rules: a container routed through the appliance does not" no "$(get ctr 169.254.169.254)"
expect "with the rules: nor does it reach another link-local address" no "$(get ctr 169.254.10.10)"
expect "with the rules: root reaches the IPv6 metadata address, another user does not" "yes|no" \
    "$(get root "$md6")|$(get nobody "$md6")"
expect "with the rules: a container'"'"'s packet to the IPv6 metadata address is refused by the forward rule" "no|yes" \
    "$(get ctr "$ctr6")|$([ "$(packets kamerplanter_metadata forward)" -gt 0 ] 2>/dev/null && echo yes)"
expect "with the rules: everything else stays reachable, for the user and the container" "yes|yes" \
    "$(get nobody 192.0.2.10)|$(get ctr 192.0.2.10)"
start=$(date +%s%N)
get nobody 169.254.169.254 >/dev/null
expect "with the rules: a refused request fails at once, without waiting for a timeout" yes \
    "$([ $((($(date +%s%N) - start) / 1000000)) -lt 2000 ] && echo yes || echo no)"

kill "$server" 2>/dev/null
if [ "$failures" -gt 0 ]; then echo "$failures check(s) failed"; exit 1; fi
echo "all checks passed"
'

exec podman run --rm --privileged --network none -e QUADLET_CHECK="$quadlet_check" "$image" bash -c "$inner"
