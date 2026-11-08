#!/bin/sh
# spitz-setup.sh: make a GL.iNet Spitz (GL-X3000) the site's Wi-Fi, as on cwwk01.
# Runs ON the Spitz. Before it goes into the CWWK, cable a laptop to the Spitz's LAN port:
#
#   scp -O spitz-setup.sh root@192.168.9.1:/tmp/
#   ssh -t root@192.168.9.1 sh /tmp/spitz-setup.sh            (SSIDs BR2026_2 / BR2026_5)
#   ssh -t root@192.168.9.1 sh /tmp/spitz-setup.sh NAME_2 NAME_5
#
# Both Wi-Fi bands go onto VLAN 40 of the LAN port with no DHCP of their own: the
# CWWK's router hands out addresses on the site LAN. The Spitz keeps its own LAN
# (192.168.9.1, untagged), which is how the CWWK uses it as a cellular modem.
# Asks for the Wi-Fi password (hidden; Enter keeps the current one).
# Original settings kept as /etc/config/{network,wireless,dhcp}.bak-blackrelay.
set -e
S2=${1:-BR2026_2} S5=${2:-BR2026_5}
uci -q get wireless.wifi2g >/dev/null && uci -q get wireless.wifi5g >/dev/null ||
	{ echo "this doesn't look like a Spitz (no wireless.wifi2g / wifi5g)"; exit 1; }
LANIF=$(uci -q get network.lan.device || echo br-lan)
PORT=${PORT:-eth1}   # the Spitz's LAN port (eth1 on the GL-X3000, as on cwwk01)
ip link show "$PORT" >/dev/null 2>&1 || { echo "no port $PORT here (set PORT=...)"; exit 1; }
printf 'Wi-Fi password for %s / %s (hidden, Enter = keep current): ' "$S2" "$S5"
stty -echo 2>/dev/null; read -r PW; stty echo 2>/dev/null; echo
if [ -n "$PW" ] && [ ${#PW} -lt 8 ]; then echo "Wi-Fi passwords need 8 characters or more"; exit 1; fi

for f in network wireless dhcp; do
	[ -f /etc/config/$f.bak-blackrelay ] || cp -a /etc/config/$f /etc/config/$f.bak-blackrelay
done
# VLAN 40 on the LAN port -> bridge br-site (no address: the CWWK router serves it)
uci -q delete network.site_vlan || true
uci -q delete network.site_br || true
uci -q delete network.site || true
uci set network.site_vlan=device
uci set network.site_vlan.type=8021q
uci set network.site_vlan.ifname="$PORT"
uci set network.site_vlan.vid=40
uci set network.site_vlan.name="$PORT.40"
uci set network.site_br=device
uci set network.site_br.type=bridge
uci set network.site_br.name=br-site
uci add_list network.site_br.ports="$PORT.40"
uci set network.site=interface
uci set network.site.device=br-site
uci set network.site.proto=none
uci set network.site.force_link=1
uci commit network
for r in wifi2g wifi5g; do
	uci set wireless.$r.network=site
	[ -n "$PW" ] && { uci set wireless.$r.encryption=psk2; uci set wireless.$r.key="$PW"; }
done
uci set wireless.wifi2g.ssid="$S2"
uci set wireless.wifi5g.ssid="$S5"
uci commit wireless
PW=
uci -q delete dhcp.site || true
uci set dhcp.site=dhcp
uci set dhcp.site.interface=site
uci set dhcp.site.ignore=1
uci commit dhcp
echo "applied: $S2 / $S5 on VLAN 40 of $PORT (LAN $LANIF unchanged). Wi-Fi restarts now."
echo "Cable the Spitz's LAN port into any CWWK port; the CWWK finds it by itself."
(sleep 2; /etc/init.d/network reload; sleep 5; wifi reload) >/dev/null 2>&1 </dev/null &
