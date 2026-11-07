#!/usr/bin/env bash
# gt-lab — three-lane bonding lab in Linux network namespaces.
#
#   site <--- veth isp      ---> vps     20ms  300Mbit 0.1% loss
#        <--- veth starlink  ---> vps     45ms  150Mbit 0.5% loss + spikes
#        <--- veth cell      ---> vps     60ms   40Mbit 1%   loss
#
# Two namespaces, three veth pairs, tc netem per lane. This gives a real
# Linux kernel datapath to run Glorytun (or the probe tools) across, with
# controllable per-lane delay / rate / loss, so the problem and the fix can
# be reproduced and A/B'd before any hardware is touched.
#
# Usage:
#   sudo ./lab.sh up         bring up namespaces, veths, netem
#   sudo ./lab.sh down       tear everything down
#   sudo ./lab.sh status     show links and netem qdiscs
#   sudo ./lab.sh exec site <cmd...>    run a command in a namespace
#   sudo ./lab.sh spike on|off          toggle starlink handoff spikes
#
# Addressing (point-to-point /30 per lane):
#   isp       site 10.10.1.1   vps 10.10.1.2
#   starlink  site 10.10.2.1   vps 10.10.2.2
#   cell      site 10.10.3.1   vps 10.10.3.2
#
# Requires: iproute2 (ip, tc) and root. Linux only.
set -euo pipefail

SITE=brl-site
VPS=brl-vps

# name   site_ip      vps_ip       delay   jitter  rate     loss
LANES=(
  "isp       10.10.1.1 10.10.1.2 20ms  2ms  300mbit 0.1%"
  "starlink  10.10.2.1 10.10.2.2 45ms  8ms  150mbit 0.5%"
  "cell      10.10.3.1 10.10.3.2 60ms 25ms   40mbit 1%"
)

need_root() { [ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }; }

up() {
  need_root
  ip netns add "$SITE"
  ip netns add "$VPS"
  ip netns exec "$SITE" ip link set lo up
  ip netns exec "$VPS"  ip link set lo up

  for lane in "${LANES[@]}"; do
    set -- $lane
    name=$1 sip=$2 vip=$3 delay=$4 jit=$5 rate=$6 loss=$7
    s="s-$name"; v="v-$name"
    ip link add "$s" type veth peer name "$v"
    ip link set "$s" netns "$SITE"
    ip link set "$v" netns "$VPS"
    ip netns exec "$SITE" ip addr add "$sip/30" dev "$s"
    ip netns exec "$VPS"  ip addr add "$vip/30" dev "$v"
    ip netns exec "$SITE" ip link set "$s" up
    ip netns exec "$VPS"  ip link set "$v" up
    # netem on both directions so delay/loss is symmetric
    ip netns exec "$SITE" tc qdisc add dev "$s" root netem \
        delay "$delay" "$jit" distribution normal rate "$rate" loss "$loss"
    ip netns exec "$VPS"  tc qdisc add dev "$v" root netem \
        delay "$delay" "$jit" distribution normal rate "$rate" loss "$loss"
    echo "lane $name up: site $sip <-> vps $vip  ($delay±$jit $rate loss $loss)"
  done
  echo "lab up. e.g.: sudo $0 exec vps ./analysis/relay-probe.py recv --listen 10.10.1.2:9999"
}

down() {
  need_root
  ip netns del "$SITE" 2>/dev/null || true
  ip netns del "$VPS"  2>/dev/null || true
  echo "lab down."
}

status() {
  need_root
  for ns in "$SITE" "$VPS"; do
    echo "=== $ns ==="
    ip netns exec "$ns" ip -br addr 2>/dev/null || { echo "(absent)"; continue; }
    ip netns exec "$ns" tc qdisc show | grep netem || true
  done
}

spike() {
  need_root
  s="s-starlink"; v="v-starlink"
  case "${1:-}" in
    on)
      ip netns exec "$SITE" tc qdisc change dev "$s" root netem \
          delay 45ms 8ms distribution normal rate 150mbit loss 0.5% \
          reorder 0% 2>/dev/null || true
      # add a big transient delay to emulate a handoff
      ip netns exec "$SITE" tc qdisc change dev "$s" root netem \
          delay 250ms 80ms distribution normal rate 150mbit loss 2%
      ip netns exec "$VPS" tc qdisc change dev "$v" root netem \
          delay 250ms 80ms distribution normal rate 150mbit loss 2%
      echo "starlink spike ON (250ms, 2% loss)"
      ;;
    off)
      ip netns exec "$SITE" tc qdisc change dev "$s" root netem \
          delay 45ms 8ms distribution normal rate 150mbit loss 0.5%
      ip netns exec "$VPS" tc qdisc change dev "$v" root netem \
          delay 45ms 8ms distribution normal rate 150mbit loss 0.5%
      echo "starlink spike OFF"
      ;;
    *) echo "usage: $0 spike on|off" >&2; exit 1;;
  esac
}

cmd="${1:-}"; shift || true
case "$cmd" in
  up)     up ;;
  down)   down ;;
  status) status ;;
  spike)  spike "$@" ;;
  exec)
    need_root
    ns="$1"; shift
    case "$ns" in site) ns=$SITE;; vps) ns=$VPS;; esac
    exec ip netns exec "$ns" "$@"
    ;;
  *) echo "usage: $0 {up|down|status|exec <site|vps> <cmd>|spike on|off}" >&2; exit 1;;
esac
