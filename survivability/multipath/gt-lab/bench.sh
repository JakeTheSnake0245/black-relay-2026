#!/usr/bin/env bash
# gt-lab/bench.sh — run one A/B measurement across the lab tunnel.
#
#   sudo ./bench.sh <label> <glorytun-bin> <cli_env> <srv_env> <rate> <size> <dur>
#
# Starts the tunnel with the given per-end env, sends a probe flow from site
# to the vps overlay address, and prints the receiver's final summary line.
# Requires ./lab.sh up.
set -euo pipefail
LABEL="$1"; BIN="$2"; CLI_ENV="$3"; SRV_ENV="$4"
RATE="${5:-500}"; SIZE="${6:-400}"; DUR="${7:-8}"
HERE="$(cd "$(dirname "$0")" && pwd)"
PROBE=/tmp/mp/analysis/relay-probe.py

cd "$HERE"
sudo ./tunnel.sh down >/dev/null 2>&1 || true
sudo pkill -f glorytun 2>/dev/null || true
sleep 1

CLI_ENV="$CLI_ENV" SRV_ENV="$SRV_ENV" sudo -E ./tunnel.sh up "$BIN" >/tmp/bench-up.log 2>&1
sleep 2
# confirm tunnel passes traffic
if ! sudo ip netns exec brl-site ping -c1 -W2 10.255.0.2 >/dev/null 2>&1; then
    echo "[$LABEL] TUNNEL DOWN - see /tmp/bench-up.log /tmp/gt-*.log"; exit 1
fi

sudo ip netns exec brl-vps python3 "$PROBE" recv --listen 10.255.0.2:9999 \
    --interval "$DUR" >/tmp/bench-recv.out 2>&1 &
sleep 1
sudo ip netns exec brl-site python3 "$PROBE" send --to 10.255.0.2:9999 \
    --rate "$RATE" --size "$SIZE" --duration "$DUR" >/dev/null 2>&1
sleep 1
sudo pkill -f relay-probe 2>/dev/null || true
printf '[%s]\n' "$LABEL"
grep -E "FINAL|live" /tmp/bench-recv.out | tail -1
# resequencer stats if the server logged any
grep -i reseq /tmp/gt-srv.log 2>/dev/null | tail -1 || true
