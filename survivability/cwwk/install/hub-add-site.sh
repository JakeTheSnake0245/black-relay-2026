#!/bin/bash
# hub-add-site.sh: register CWWK site N at the BR2026 hub and write its join file.
# Run on BR2026 (sudo). Prints no secrets.
#
#   sudo bash hub-add-site.sh 2
#
# Site N gets: transit 10.(39+8(N-1)).0.0/30, LAN 10.(40+8(N-1)).0.0/24,
# services 10.(41+8(N-1)).0.0/24 (all inside 10.32.0.0/11), routed through its tunnel.
# Writes ~/cwwkNN.join (0600, owned by you): the tunnel join token, the HTTPS lane
# path prefix and a one-hour tag-only tailnet key for the CWWK host. Copy it to the
# new CWWK, then delete it here.
set -euo pipefail
N=${1:-}
[[ "$N" =~ ^[2-9]$ ]] || { echo "usage: sudo bash hub-add-site.sh <site number 2-9>"; exit 2; }
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
SITE=cwwk$(printf %02d "$N"); O=$((8 * (N - 1)))
TR=10.$((39 + O)).0.0/30 LAN=10.$((40 + O)).0.0/24 SVC=10.$((41 + O)).0.0/24
HUB=survivability-black-relay HS=survivability-headscale
OWNER=${SUDO_USER:-root}; HOMEDIR=$(getent passwd "$OWNER" | cut -d: -f6)
OUT=$HOMEDIR/$SITE.join

if docker exec $HUB black-relay-hub token "$SITE" >/dev/null 2>&1; then
	echo "site $SITE already registered at the hub (reusing it)"
else
	docker exec $HUB black-relay-hub add "$SITE" --lan $TR --lan $LAN --lan $SVC >/dev/null
	echo "site $SITE registered: LAN $LAN, services $SVC, transit $TR"
fi
docker exec $HUB black-relay-hub list | awk -v s="$SITE" 'NR==1 || $1==s'

umask 077
tok=$(docker exec $HUB black-relay-hub token "$SITE" | tail -1)
pre=$(sed -n 's/^BR_WS_PREFIX=//p' /srv/black-relay/ws.env | head -1)
[ -n "$tok" ] && [ -n "$pre" ] || { echo "could not read the join token or the lane prefix"; exit 1; }
ts=$(docker exec $HS headscale preauthkeys create --tags tag:proxmox-subnet-router --expiration 1h -o json 2>/dev/null |
	python3 -c 'import json,sys; print(json.load(sys.stdin)["key"])' 2>/dev/null || true)
{
	echo "SITE=$SITE"
	echo "N=$N"
	echo "JOIN_TOKEN=$tok"
	echo "WSS_PREFIX=$pre"
	echo "TS_AUTHKEY=$ts"
} >"$OUT"
unset tok pre ts
chown "$OWNER" "$OUT"; chmod 600 "$OUT"
grep -q '^TS_AUTHKEY=.\+' "$OUT" && t="included (1 hour)" || t="NOT included: make one later (see the install README)"
echo
echo "join file: $OUT (secret; delete it after the install)  tailnet key: $t"
echo "next, on your Mac:  scp jake@100.64.0.5:$SITE.join ~/Desktop/"
