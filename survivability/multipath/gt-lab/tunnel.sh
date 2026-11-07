#!/usr/bin/env bash
# gt-lab/tunnel.sh — run a Glorytun tunnel across the three lab lanes.
#
# Requires ./lab.sh up first. Starts a server in the vps namespace and a
# client in the site namespace, bonds all three lanes, and brings up the
# overlay:
#
#   site tun = 10.255.0.1/30   <--- bonded --->   vps tun = 10.255.0.2/30
#
# Then run the probe across the overlay, e.g.:
#   sudo ../gt-lab/lab.sh exec vps  ./analysis/relay-probe.py recv --listen 10.255.0.2:9999
#   sudo ../gt-lab/lab.sh exec site ./analysis/relay-probe.py send --to 10.255.0.2:9999 --rate 20 --size 200 --echo
#
# Usage:
#   sudo ./tunnel.sh up [path-to-glorytun-binary]   default: ./glorytun
#   sudo ./tunnel.sh down
#   sudo ./tunnel.sh paths        show path status on both ends
#
# Env:
#   GT          glorytun binary (default ./glorytun or $PWD/glorytun)
#   PORT        server UDP port (default 5000)
#   RATES       per-lane fixed rate in bits (default from lane profile)
set -euo pipefail

SITE=brl-site
VPS=brl-vps
PORT="${PORT:-5000}"
KEY=/tmp/gt-lab.key
SRV_DEV=brls
CLI_DEV=brlc
GT="${GT:-./glorytun}"

# Rates are bytes/sec (glorytun's internal unit): 300/150/40 Mbit.
# name   site_src     vps_dst      fixed_tx(B/s) fixed_rx(B/s)
PATHS=(
  "isp       10.10.1.1 10.10.1.2 37500000 37500000"
  "starlink  10.10.2.1 10.10.2.2 18750000 18750000"
  "cell      10.10.3.1 10.10.3.2  5000000  5000000"
)

need_root() { [ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }; }
nse() { ip netns exec "$1" "${@:2}"; }

up() {
  need_root
  [ -n "${1:-}" ] && GT="$1"
  [ -x "$GT" ] || { echo "glorytun binary not found/executable: $GT" >&2; exit 1; }
  GT="$(readlink -f "$GT")"

  [ -f "$KEY" ] || "$GT" keygen > "$KEY"

  # SRV_ENV / CLI_ENV inject per-end Black Relay settings, e.g.
  #   CLI_ENV="GT_SCHED=arrival" SRV_ENV="GT_RESEQ=1 GT_RESEQ_MS=40"
  # server: bind 0.0.0.0:PORT in the vps ns (passive; learns paths on arrival)
  nse "$VPS" env ${SRV_ENV:-} "$GT" bind dev "$SRV_DEV" keyfile "$KEY" \
      from port "$PORT" >/tmp/gt-srv.log 2>&1 &
  echo "server pid $! (log /tmp/gt-srv.log)  env: ${SRV_ENV:-none}"

  # client: bind 0.0.0.0:PORT in the site ns (per-path source set via PKTINFO)
  nse "$SITE" env ${CLI_ENV:-} "$GT" bind dev "$CLI_DEV" keyfile "$KEY" \
      from port "$PORT" >/tmp/gt-cli.log 2>&1 &
  echo "client pid $! (log /tmp/gt-cli.log)  env: ${CLI_ENV:-none}"

  sleep 1

  # overlay addresses on the tun devices
  nse "$VPS"  ip addr add 10.255.0.2/30 dev "$SRV_DEV"
  nse "$VPS"  ip link set "$SRV_DEV" up
  nse "$SITE" ip addr add 10.255.0.1/30 dev "$CLI_DEV"
  nse "$SITE" ip link set "$CLI_DEV" up

  # client adds one UP path per lane, fixed rate from the profile
  for p in "${PATHS[@]}"; do
    set -- $p
    name=$1 src=$2 dst=$3 tx=$4 rx=$5
    nse "$SITE" "$GT" path dev "$CLI_DEV" addr "$src" to addr "$dst" port "$PORT" \
        set up rate fixed tx "$tx" rx "$rx" >/dev/null
    echo "path $name: $src -> $dst:$PORT  tx=$tx rx=$rx"
  done

  sleep 1
  echo "tunnel up. overlay: site 10.255.0.1 <-> vps 10.255.0.2"
}

down() {
  need_root
  pkill -f "$SRV_DEV" 2>/dev/null || true
  pkill -f "$CLI_DEV" 2>/dev/null || true
  pkill -f "bind dev $SRV_DEV" 2>/dev/null || true
  pkill -f "bind dev $CLI_DEV" 2>/dev/null || true
  echo "tunnel down."
}

paths() {
  need_root
  echo "=== client paths (site) ==="
  nse "$SITE" "$GT" path dev "$CLI_DEV" show stat 2>/dev/null || true
  nse "$SITE" "$GT" path dev "$CLI_DEV" show rtt 2>/dev/null || true
  echo "=== server paths (vps) ==="
  nse "$VPS" "$GT" path dev "$SRV_DEV" show stat 2>/dev/null || true
}

cmd="${1:-}"; shift || true
case "$cmd" in
  up)    up "${1:-}" ;;
  down)  down ;;
  paths) paths ;;
  *) echo "usage: $0 {up [glorytun-bin]|down|paths}" >&2; exit 1 ;;
esac
