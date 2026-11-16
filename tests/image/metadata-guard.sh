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
# answering on 169.254.169.254 and, as a control, on 192.0.2.10). A table
# that accepts everything, as Podman's netavark keeps its own, is loaded
# first. The checks run once without the rules, so that they can fail, and
# once with them, loaded twice as on a restart of the unit.
#
# Runs in the tool container, after `task image:build`:
#   build/in-tools.sh tests/image/metadata-guard.sh [IMAGE]
set -euo pipefail

image=${1:-${IMAGE_REF:-localhost/kamerplanter-appliance:poc}}

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
    if "${prefix[@]}" curl -s -o /dev/null --max-time 3 "http://$2/" 2>/dev/null; then echo yes; else echo no; fi
}

expect "the rules pass nft'"'"'s check" 0 "$(nft -c -f "$rules" >/dev/null 2>&1; echo $?)"

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
ip route add 192.0.2.10/32 via 192.0.2.2 dev br-md
ip netns exec ctr ip link set lo up
ip netns exec ctr ip addr add 10.88.0.2/24 dev eth0
ip netns exec ctr ip link set eth0 up
ip netns exec ctr ip route add default via 10.88.0.1
ip netns exec md ip link set lo up
ip netns exec md ip addr add 192.0.2.2/30 dev eth0
ip netns exec md ip addr add 169.254.169.254/32 dev lo
ip netns exec md ip addr add 192.0.2.10/32 dev lo
ip netns exec md ip link set eth0 up
ip netns exec md ip route add 10.88.0.0/24 via 192.0.2.1
echo 1 >/proc/sys/net/ipv4/ip_forward
ip netns exec md python3 -m http.server --bind 0.0.0.0 80 >/dev/null 2>&1 &
server=$!
for _ in $(seq 50); do [ "$(get root 192.0.2.10)" = yes ] && break; sleep 0.2; done

# A table of another owner that accepts everything, as netavark keeps its own.
nft -f - <<EOF
table inet netavark {
    chain forward { type filter hook forward priority filter; policy accept; ip daddr 169.254.169.254 accept; }
    chain output { type filter hook output priority filter; policy accept; ip daddr 169.254.169.254 accept; }
}
EOF

expect "without the rules: root, another user and a container reach the metadata service" "yes|yes|yes" \
    "$(get root 169.254.169.254)|$(get nobody 169.254.169.254)|$(get ctr 169.254.169.254)"

nft -f "$rules" && nft -f "$rules"
expect "the rules load, also a second time, as one table beside the other" "yes|1|yes" \
    "$(nft list tables | grep -qx "table inet kamerplanter_metadata" && echo yes)|$(nft list tables | grep -cx "table inet kamerplanter_metadata")|$(nft list tables | grep -qx "table inet netavark" && echo yes)"
expect "with the rules: root reaches the metadata service" yes "$(get root 169.254.169.254)"
expect "with the rules: another user does not" no "$(get nobody 169.254.169.254)"
expect "with the rules: a container routed through the appliance does not" no "$(get ctr 169.254.169.254)"
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

exec podman run --rm --privileged --network none "$image" bash -c "$inner"
