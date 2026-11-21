#!/bin/bash
# cwwk-addon.sh: add the Black Relay multipath EDGE to a Proxmox box that already runs its own
# router/firewall (the Quezada build: cwwk02, OPNsense VM 100). Runs ON the node, as root.
#
#   bash cwwk-addon.sh survey            read-only: what is here, and what would block the install
#   bash cwwk-addon.sh plan              prints exactly what 'apply' will do (still read-only)
#   bash cwwk-addon.sh apply JOINFILE    PHASE 1: br-edge container (ID 110), joined to the hub
#   bash cwwk-addon.sh status            edge + tunnel health
#   bash cwwk-addon.sh ports             LATER, with a real modem in nic0/nic1: gives those ports their own VLANs and the
#                                        edge a NIC for each (persistent). Touches nic0/nic1 only; never nic2 or OPNsense
#   bash cwwk-addon.sh rollback          removes only what 'apply' made (CT 110, its files)
#   bash cwwk-addon.sh wifi              puts the Spitz's Wi-Fi (VLAN 40) onto the LAN (veth patch vmbr10 -> vmbr1); wifi-rollback undoes it
#   bash cwwk-addon.sh controller        PHASE 3: the controller web UI (CT 111, https://172.22.100.7); needs /root/.opn-api (key=/secret=)
#   bash cwwk-addon.sh controller-oidc      stores the Pocket ID client (id + secret) in the controller: ssh -t, then sign in at headscale.l8s.dev/cwwk2/
#   bash cwwk-addon.sh controller-rollback   removes CT 111, its Proxmox token and its key on the edge
#
# PHASE 1 TOUCHES NOTHING THAT EXISTS: no existing bridge, VM, route, package source, DNS or SSH
# setting is changed. It adds one container (br-edge) whose uplink NICs sit on the existing VLAN-aware
# port bridge (vmbr10) as tagged VLANs and whose transit NIC sits on vmbr2. OPNsense keeps its WAN,
# its Tailscale (= everyone's remote access) and every address. Moving OPNsense behind the edge is
# PHASE 2 (OPNSENSE.md), a separate, reversible, supervised step.
#
# Design (docs/cwwk02-opnsense-plan.md):
#   uplinks   up0 = the native segment of nic2 (UPLINK_VLANS=1): today the Spitz's modem LAN 192.168.9.0/24 (T-Mobile),
#             DHCP from it, shared with OPNsense's WAN. More modems later: 'ports' (nic0/nic1, own VLANs).
#   transit   10.47.0.0/29 on vmbr2: edge .1, OPNsense .2 (phase 2), controller .3 (later)
#   OPNsense NATs its LAN/services onto 10.47.0.2, so the hub only needs the transit range
# All values below can be overridden from the environment (e.g. UPLINK_VLANS="101 102 103").
set -euo pipefail
KIT=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo /root/quezada)

SITE=${SITE:-cwwk02} N=${N:-2}
EDGE=${EDGE:-110}                       # IDs 100-102 are VMs here, so not 101
TRANSIT=${TRANSIT:-10.47.0} TLEN=${TLEN:-29}   # edge .1  firewall .2  controller .3
BR_TRANSIT=${BR_TRANSIT:-vmbr2}
BR_UP=${BR_UP:-vmbr10}                  # VLAN-aware port bridge (nic0-2)
UPLINK_VLANS=${UPLINK_VLANS:-"1"}       # the edge's uplinks: 1 = the port bridge's native (untagged) segment, e.g. the Spitz's
                                        # modem LAN on nic2 (what the node is cabled to now); other numbers = tagged VLAN IDs
MODEM_PORTS=${MODEM_PORTS:-"nic0 nic1"} # ports kept for real modems later ('ports' step): each gets its own VLAN
PVID_BASE=${PVID_BASE:-200}             #   PVID_BASE + index (200, 201), never clashing with VLANs a neighbour may use
BR_DL=${BR_DL:-vmbr1}                   # temporary NIC for the install downloads, removed afterwards
DL_DNS=${DL_DNS:-172.22.100.5}          # OPNsense resolver (the host's own resolv.conf is dead)
STORE=${STORE:-local-lvm}
TPL=${TPL:-debian-13-standard_13.6-1_amd64.tar.zst}
EDGE_MEM=${EDGE_MEM:-1024}
MGMT_IP=${MGMT_IP:-172.22.100.6/24}        # edge LAN port: the multipath dashboard at http://172.22.100.6:8088 (static, outside the DHCP pool .41-.245)
CTRL=${CTRL:-111}                       # PHASE 3: the controller web UI (same as cwwk01's), CT 111
CTRL_IP=${CTRL_IP:-172.22.100.7/24}     # its LAN address: https://172.22.100.7 (LAN + tailnet); its transit address is .3
CTRL_GW=${CTRL_GW:-172.22.100.5}
OPN_HOST=${OPN_HOST:-$DL_DNS}           # OPNsense (the router the controller reads)
SVC_VM=${SVC_VM:-172.22.41.10}          # services VM (RF console, MQTT, video)
TAK_VM=${TAK_VM:-172.22.41.15}          # TAK server
D=/root/black-relay
# umask 022, NOT 077: 'pct create' unpacks the template under the caller's umask and the unprivileged container's
# tar cannot write into 0700 directories (found on the first real run: "tar ... failed: exit code 2"). Secrets do
# not rely on the umask: the join file is installed 0600, the work dir is chmod 700, pushed files carry --perms.
umask 022

say()  { printf '\n== %s\n' "$*"; }
die()  { echo "STOP: $*" >&2; exit 1; }
ok()   { printf '  ok      %s\n' "$*"; }
warn() { printf '  WARN    %s\n' "$*"; }
bad()  { printf '  BLOCKER %s\n' "$*"; BLOCK=$((BLOCK + 1)); }
guest_of() { local f; for f in /etc/pve/nodes/*/lxc/$1.conf; do [ -e "$f" ] && { echo "CT $(sed -n 's/^hostname: //p' "$f")"; return; }; done
             for f in /etc/pve/nodes/*/qemu-server/$1.conf; do [ -e "$f" ] && { echo "VM $(sed -n 's/^name: //p' "$f")"; return; }; done; return 0; }
vlab() { [ "$1" = 1 ] && echo "native/untagged (VLAN 1)" || echo "VLAN $1"; }
vlan_on_port() { # port vid -> yes if the port carries that VLAN
	bridge vlan show dev "$1" 2>/dev/null | awk -v v="$2" '{for(i=1;i<=NF;i++) if($i==v){f=1}} END{exit !f}'
}

# ------------------------------------------------------------------ survey (read-only)
cmd_survey() {
	BLOCK=0
	say "survey of this box (nothing is changed)"
	command -v pct >/dev/null || die "this is not a Proxmox host"
	echo "  $(pveversion | head -1)   host $(hostname -s)   $(awk '/MemTotal/{printf "%.1f GiB RAM", $2/1048576}' /proc/meminfo)"
	g=$(guest_of "$EDGE"); if [ -n "$g" ]; then
		if [ "$g" = "CT br-edge" ]; then warn "guest ID $EDGE is already br-edge (an earlier add-on run): 'apply' will refuse; use 'status' or 'rollback'"
		else bad "guest ID $EDGE is already used by $g"; fi
	else ok "guest ID $EDGE is free"; fi
	for b in "$BR_TRANSIT" "$BR_UP" "$BR_DL"; do ip link show "$b" >/dev/null 2>&1 && ok "bridge $b exists" || bad "bridge $b is missing"; done
	if [ "$(cat /sys/class/net/$BR_UP/bridge/vlan_filtering 2>/dev/null)" = 1 ]; then ok "$BR_UP is VLAN-aware"; else bad "$BR_UP is not VLAN-aware"; fi
	ports=$(ls /sys/class/net/$BR_UP/brif 2>/dev/null | grep -E '^nic' | tr '\n' ' ')
	echo "  $BR_UP ports: ${ports:-none}"
	for v in $UPLINK_VLANS; do
		hit=""; for p in $ports; do vlan_on_port "$p" "$v" && hit="$hit $p"; done
		if [ -n "$hit" ]; then ok "uplink segment $(vlab "$v") is carried by:$hit"
		else bad "VLAN $v is not carried by any $BR_UP port (add it to the bridge's vids and the port first; Phase 1 does not change existing bridges)"; fi
	done
	for p in $ports; do printf '  %-6s link %s\n' "$p" "$(cat /sys/class/net/$p/carrier 2>/dev/null || echo ?)"; done
	if ip -4 addr show dev "$BR_TRANSIT" 2>/dev/null | grep -q "inet $TRANSIT\."; then bad "$BR_TRANSIT already has an address in $TRANSIT.0/$TLEN"; fi
	if [ -n "$(ls /sys/class/net/$BR_TRANSIT/brif 2>/dev/null)" ]; then warn "$BR_TRANSIT already has members: $(ls /sys/class/net/$BR_TRANSIT/brif | tr '\n' ' ')"; else ok "$BR_TRANSIT has no members (free for the transit)"; fi
	storage=$(pvesm status --content rootdir 2>/dev/null | awk -v s="$STORE" 'NR>1 && $1==s && $3=="active"{print $6}')
	[ -n "$storage" ] && ok "storage $STORE active ($((storage / 1048576)) GiB free)" || bad "storage $STORE is not active"
	avail=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo); sw=$(awk '/SwapTotal/{t=$2}/SwapFree/{f=$2}END{printf "%d/%d MiB swap used", (t-f)/1024, t/1024}' /proc/meminfo)
	if [ "$avail" -lt $((EDGE_MEM + 256)) ]; then warn "only $avail MiB RAM available ($sw): the edge (limit ${EDGE_MEM} MiB, about 300 MiB in real use) will push the host into swap. REMINDER (Jake): this node's VM RAM is over-committed (20 GiB on 15.7 GiB)"
	else ok "$avail MiB RAM available ($sw)"; fi
	if ls /var/lib/vz/template/cache/"$TPL" >/dev/null 2>&1; then ok "template $TPL present"
	elif [ -s "$KIT/templates/$TPL" ]; then ok "template ships in the kit"
	elif [ ! -d "$KIT/templates" ]; then ok "template: comes with the kit (not unpacked on this box yet)"
	else warn "template $TPL is neither on the box nor in the kit"; fi
	getent hosts deb.debian.org >/dev/null 2>&1 && ok "host DNS works" || warn "host DNS does not resolve (Phase 1 does not need it: the edge downloads through $BR_DL using $DL_DNS)"
	if timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -qx yes; then ok "clock is NTP-synchronised"; else warn "clock is not NTP-synchronised (TLS to the hub tolerates a few minutes; check 'date -u')"; fi
	vm=$(guest_of 100); echo "  VM 100: ${vm:-none}   (OPNsense is not touched in Phase 1)"
	echo "  ip rule/route are not changed. Uplink VLANs for the edge: $UPLINK_VLANS"
	[ "$BLOCK" -eq 0 ] && { echo; echo "survey: nothing blocks Phase 1"; return 0; }
	echo; echo "survey: $BLOCK blocker(s); nothing was changed"; return 1
}

# ------------------------------------------------------------------ plan
cmd_plan() {
	local i=0 v
	cat <<EOF
Phase 1 would do, in this order (each step only ADDS):
  1. check the kit (SHA256SUMS), the join file (site $SITE), and run the survey above
  2. copy the Debian template into /var/lib/vz/template/cache if it is not there
  3. create CT $EDGE 'br-edge' (2 cores, ${EDGE_MEM} MiB, 8 GiB on $STORE, unprivileged, onboot):
       net0  tr0   on $BR_TRANSIT   $TRANSIT.1/$TLEN        (transit; OPNsense joins it in phase 2)
EOF
	for v in $UPLINK_VLANS; do echo "       net$((i + 1))  up$i   on $BR_UP $([ "$v" = 1 ] && echo 'untagged (native segment)' || echo "tag $v")   DHCP from the modem on that segment (no routes taken from it)"; i=$((i + 1)); done
	cat <<EOF
       net9  eth9  on $BR_DL   temporary, DHCP, only for the downloads below; removed afterwards
  4. in the CT: apt dnsmasq nftables sshpass curl python3; black-relay-glorytun (br7, same binary as the hub);
     wstunnel; the edge files from cwwk01's as-built tree with this site's addresses (leak guard, uplink
     detection, fail-closed egress); join the hub with the site token; HTTPS lanes (WSS_PREFIX)
  5. remove the temporary NIC, point the CT's resolver at its own dnsmasq, start it
  6. wait for the tunnel and print the proof (paths, hub ping, exit address)
Not done in Phase 1: OPNsense (no NIC, no gateway, no NAT), host DNS/NTP, site lock, controller, any
existing bridge or port setting. Undo everything: 'bash cwwk-addon.sh rollback'.
EOF
}

# ------------------------------------------------------------------ render (read-only)
# cwwk01's edge tree -> this site's edge tree. cmd: cwwk-addon.sh render SRC OUT IDX shows exactly what a site gets.
render_edge() { # src out idx
	local SRC=$1 W=$2 IDX=$3 i f
	local NUP; NUP=$(echo $UPLINK_VLANS | wc -w)
	cp -a "$SRC/." "$W/"
	for i in $(seq 0 $((NUP - 1))); do
		[ -f "$W/etc/systemd/network/20-up$i.network" ] || sed "s/up0/up$i/g; s/nic0/uplink$i/g" "$W/etc/systemd/network/20-up0.network" >"$W/etc/systemd/network/20-up$i.network"
	done
	# cwwk01's addresses -> this site. Order matters: the controller first, then the ranges.
	#   10.40.0.10 (controller)  -> transit .3        10.40.0.1 (router/edge) -> transit .1        10.40.0.0/24 (site devices) -> the transit /29 (OPNsense NATs them to .2)
	#   10.39.0.x (transit)      -> $TRANSIT.x        tunnel index 1 -> $IDX
	find "$W/etc" "$W/usr" -type f -print0 | while IFS= read -r -d '' f; do
		sed -i.orig -E -e "s#\b10\.40\.0\.10\b#$TRANSIT.3#g" -e "s#\b10\.40\.0\.1\b#$TRANSIT.1#g" -e "s#\b10\.40\.0\.0/24#$TRANSIT.0/$TLEN#g" \
			-e "s#\b10\.39\.0\.#$TRANSIT.#g" -e "s#\b10\.255\.1\.([12])\b#10.255.$IDX.\1#g" \
			-e "s/cwwk-node01/cwwk-node$(printf %02d "$N")/g" -e "s/\bcwwk01\b/$SITE/g" "$f" && rm -f "$f.orig"
	done
	# br-edge-routes: cwwk01 pointed its LAN/services ranges at the router. Here OPNsense NATs onto the
	# transit, so there are no such ranges: drop that first block; the connected transit route is what
	# table 201 needs (the second tr0 block, the 201 sync, stays).
	awk 'BEGIN{n=0;skip=0} /^if ip link show dev tr0/ && n==0 {n=1; skip=1} skip{ if ($0 ~ /^fi/) skip=0; next} {print}' \
		"$W/usr/local/sbin/br-edge-routes" >"$W/.r" && mv "$W/.r" "$W/usr/local/sbin/br-edge-routes"
	sed -i.orig '2a\
# Quezada: no LAN/services ranges behind the transit; OPNsense NATs everything onto it.' "$W/usr/local/sbin/br-edge-routes" && rm -f "$W/usr/local/sbin/br-edge-routes.orig"
	if grep -qE 'via 10\.[0-9]+\.0\.2 dev tr0|10\.4[01]\.0\.' <(grep -v '^#' "$W/usr/local/sbin/br-edge-routes"); then die "br-edge-routes still routes cwwk01 ranges (render bug)"; fi
	sh -n "$W/usr/local/sbin/br-edge-routes" || die "rendered br-edge-routes has a syntax error"
	# Site-lock gate: the set is empty = LOCKED and cwwk01's br-lockd opens it. This build has no lock controller yet
	# (site lock is postponed), and with the gate shut the edge would drop all internet traffic from OPNsense (only DNS
	# and the hub pass). So it ships open for the transit range, like cwwk02 itself (no lock today). When a lock
	# controller is added, delete this element: the controller then owns the set.
	awk -v tr="$TRANSIT.0/$TLEN" '/set site_open \{/{s=1} s && /flags interval/ && !d {print; print "\t\t# Quezada build: no site-lock controller yet, so the gate is open for the transit range."; print "\t\telements = { " tr " }"; d=1; s=0; next} {print}' \
		"$W/etc/nftables.conf" >"$W/.nft" && mv "$W/.nft" "$W/etc/nftables.conf"
	# Multipath dashboard (read-only) for the site LAN + tailnet: port 8088 on the edge LAN port mgmt0 only.
	awk '/iifname "tr0" ip saddr [0-9.]+ tcp dport 8088 accept/ && !d {print; print "\t\t# multipath dashboard (read-only) for the site LAN + tailnet, on the edge LAN port only"; print "\t\tiifname \"mgmt0\" tcp dport 8088 accept"; d=1; next} {print}' \
		"$W/etc/nftables.conf" >"$W/.nft" && mv "$W/.nft" "$W/etc/nftables.conf"
	grep -q 'iifname "mgmt0" tcp dport 8088 accept' "$W/etc/nftables.conf" || die "could not add the mgmt0 dashboard rule to the rendered nftables.conf (render bug)"
	grep -q "elements = { $TRANSIT.0/$TLEN }" "$W/etc/nftables.conf" || die "could not open the site_open gate in the rendered nftables.conf (render bug)"
	if grep -rqE '\b10\.(39|40)\.0\.' "$W/etc" "$W/usr" 2>/dev/null; then
		die "cwwk01 addresses left in the rendered edge: $(grep -rlE '\b10\.(39|40)\.0\.' "$W/etc" "$W/usr" | tr '\n' ' ')"; fi
	python3 - "$W/etc/black-relay/dash.json" "$SITE" "$TRANSIT" "$UPLINK_VLANS" <<'PY'
import json, sys
p, site, tr, vl = sys.argv[1:5]
c = json.load(open(p)); c["site"] = site; c["listen"] = "0.0.0.0"
c["lanes"] = {f"up{i}": ("native segment (Spitz / modem LAN)" if v == "1" else f"VLAN {v}") for i, v in enumerate(vl.split())}
json.dump(c, open(p, "w"), indent=2)
PY
}

# ------------------------------------------------------------------ apply
cmd_apply() {
	local J=${1:-}; [ -r "$J" ] || die "join file missing (made on BR2026 by hub-add-site.sh $N)"
	[ "$(id -u)" = 0 ] || die "run as root"
	[ -r "$KIT/SHA256SUMS" ] && ( cd "$KIT" && sha256sum -c --quiet SHA256SUMS ) || die "kit files damaged or SHA256SUMS missing"
	local WANT=cwwk$(printf %02d "$N") WN=$N
	# shellcheck disable=SC1090
	. "$J"
	[ "${SITE:-}" = "$WANT" ] && [ "${N:-}" = "$WN" ] || die "join file is for ${SITE:-?} (site ${N:-?}), this add-on is for $WANT (site $WN)"
	SITE=$WANT N=$WN
	IDX=$(printf '%s' "${JOIN_TOKEN#brj1.}" | base64 -d | sed -n 's#^BR_TUN=10\.255\.\([0-9]*\)\.2/30$#\1#p')
	[ -n "$IDX" ] || die "join token unreadable"
	cmd_survey || die "nothing was changed. Fix the BLOCKER lines and run again"
	[ -z "$(guest_of "$EDGE")" ] || die "guest ID $EDGE exists: nothing to do (use status / rollback)"
	mkdir -p $D; chmod 700 $D
	printf 'SITE=%s\nN=%s\nIDX=%s\nEDGE=%s\nTRANSIT=%s\nUPLINK_VLANS="%s"\n' "$SITE" "$N" "$IDX" "$EDGE" "$TRANSIT" "$UPLINK_VLANS" >$D/addon.env
	install -m 0600 "$J" $D/$SITE.join

	say "1/4 template"
	[ -f /var/lib/vz/template/cache/$TPL ] || install -m 0644 "$KIT/templates/$TPL" /var/lib/vz/template/cache/$TPL

	say "2/4 br-edge (CT $EDGE)"
	# existing downloads NIC: DHCP on the LAN bridge, or BR_TMP_IP=addr/24 BR_TMP_GW=gw
	if [ -n "${BR_TMP_IP:-}" ]; then NET9="name=eth9,bridge=$BR_DL,ip=$BR_TMP_IP,gw=${BR_TMP_GW:-},type=veth"; else NET9="name=eth9,bridge=$BR_DL,ip=dhcp,type=veth"; fi
	nets=(-net0 "name=tr0,bridge=$BR_TRANSIT,ip=$TRANSIT.1/$TLEN,type=veth" -net9 "$NET9")
	i=0; for v in $UPLINK_VLANS; do
		nets+=(-net$((i + 1)) "name=up$i,bridge=$BR_UP$([ "$v" = 1 ] || echo ",tag=$v"),ip=manual,type=veth"); i=$((i + 1)); done
	NUP=$i
	pct create "$EDGE" local:vztmpl/$TPL --hostname br-edge --cores 2 --memory "$EDGE_MEM" --swap 256 \
		--rootfs "$STORE:8" --unprivileged 1 --features nesting=1 --onboot 1 --startup order=1 \
		--nameserver "$DL_DNS" --searchdomain lan --ostype debian "${nets[@]}" \
		--description "Black Relay site edge: bonded tunnel to BR2026 hub ($SITE). Transit $TRANSIT.0/$TLEN in front of OPNsense. Added by cwwk-addon.sh" >/dev/null
	pct set "$EDGE" -dev0 /dev/net/tun
	pct start "$EDGE"; wait_ct
	for _ in $(seq 1 20); do pct exec "$EDGE" -- getent hosts deb.debian.org >/dev/null 2>&1 && break; sleep 2; done
	pct exec "$EDGE" -- getent hosts deb.debian.org >/dev/null 2>&1 ||
		die "br-edge has no internet on $BR_DL (needs DHCP there and a resolver at $DL_DNS). Without DHCP: BR_TMP_IP=ADDRESS/24 BR_TMP_GW=GATEWAY (a free address on $BR_DL). Only CT $EDGE was added; 'rollback' removes it"
	pct exec "$EDGE" -- sh -c 'apt-get update -q >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -y -q dnsmasq nftables sshpass curl python3 >/dev/null'
	pct push "$EDGE" "$KIT/pkgs/black-relay-glorytun_0.3.4+br7_amd64.deb" /root/br.deb --perms 0644
	pct exec "$EDGE" -- sh -c 'DEBIAN_FRONTEND=noninteractive apt-get install -y -q /root/br.deb >/dev/null && rm /root/br.deb'
	tar -xzf "$KIT/pkgs/wstunnel_11.1.0_linux_amd64.tar.gz" -C $D wstunnel
	pct push "$EDGE" $D/wstunnel /usr/local/bin/wstunnel --perms 0755; rm $D/wstunnel

	say "3/4 edge files for $SITE"
	W=$(mktemp -d); render_edge "$KIT/edge" "$W" "$IDX"
	( cd "$W" && find etc usr -type f ) | while read -r f; do
		m=0644; case "$f" in usr/local/sbin/*|usr/sbin/*) m=0755 ;; esac
		pct exec "$EDGE" -- mkdir -p "/$(dirname "$f")"
		pct push "$EDGE" "$W/$f" "/$f" --perms $m
	done
	rm -rf "$W"
	pct exec "$EDGE" -- black-relay-setup join "$JOIN_TOKEN" --no-start >/dev/null
	# join records UPLINKS from the NICs it sees right now (the temporary download NIC, eth9). br-uplinks only
	# understands upN names (it crashed with int('h9') on the first real run), so name them; it fills in the caps.
	UPL=""; for ((i = 0; i < NUP; i++)); do UPL="$UPL up$i:auto"; done
	pct exec "$EDGE" -- sed -i "s|^UPLINKS=.*|UPLINKS=\"${UPL# }\"|" /etc/black-relay/br0.conf
	{ echo; cat "$KIT/edge/br0.wss.conf"; echo "WSS_PREFIX=$WSS_PREFIX"; } >$D/.wss
	pct exec "$EDGE" -- sh -c 'cat >> /etc/black-relay/br0.conf; chmod 600 /etc/black-relay/br0.conf' <$D/.wss
	shred -u $D/.wss 2>/dev/null || rm -f $D/.wss
	# The HTTPS lanes must find the hub without DNS: DNS to 1.1.1.1 rides the tunnel, which needs the lanes
	# (found on the first real run: 0 paths, "Maximum number of concurrent DNS queries"). cwwk01 has the same line.
	HUBIP=$(pct exec "$EDGE" -- sed -n 's/^SERVER=//p' /etc/black-relay/br0.conf)
	HUBHOST=$(sed -n 's#^WSS_URL=wss://\([^:/]*\).*#\1#p' "$KIT/edge/br0.wss.conf")
	[ -n "$HUBIP" ] && [ -n "$HUBHOST" ] || die "cannot work out the hub address/name for /etc/hosts"
	pct exec "$EDGE" -- sh -c "printf '# Black Relay: Multithread lanes reach the hub without DNS (DNS rides the tunnel)\n%s %s\n' '$HUBIP' '$HUBHOST' >> /etc/hosts"
	pct exec "$EDGE" -- sh -c 'systemctl daemon-reload
		systemctl enable -q systemd-networkd nftables dnsmasq br-dash br-edge-routes br-lane-nurse br-watchdog br-uplinks-recheck.timer black-relay@br0 black-relay-watch@br0
		nft -c -f /etc/nftables.conf' || die "edge firewall file does not check out (nft -c); CT $EDGE left stopped for inspection"

	say "4/4 take the download NIC away, start the edge"
	pct shutdown "$EDGE"
	pct set "$EDGE" -delete net9
	pct set "$EDGE" -net8 "name=mgmt0,bridge=$BR_DL,ip=$MGMT_IP,type=veth"   # dashboard address on the LAN: http://${MGMT_IP%/*}:8088
	pct set "$EDGE" -nameserver 127.0.0.1
	pct start "$EDGE"; wait_ct
	echo "  waiting for the tunnel (up to 90 s)..."
	for _ in $(seq 1 45); do pct exec "$EDGE" -- sh -c 'ip link show br0 2>/dev/null | grep -q ",UP"' 2>/dev/null && break; sleep 2; done
	cmd_status || true
	cat <<EOF

Phase 1 done. Nothing outside CT $EDGE changed. Multipath page: http://${MGMT_IP%/*}:8088 (site LAN + tailnet). The hub should list $SITE with paths running
(on BR2026: sudo docker exec survivability-black-relay black-relay-hub list).
Next: PHASE 2 (OPNSENSE.md): OPNsense gets a NIC on $BR_TRANSIT; its default gateway moves only in the
supervised cutover. Undo Phase 1 any time: bash cwwk-addon.sh rollback
EOF
}
wait_ct() { local c=${1:-$EDGE}; for _ in $(seq 1 30); do pct exec "$c" -- true 2>/dev/null && return 0; sleep 1; done; die "container $c did not start"; }

# ------------------------------------------------------------------ ports (later, with a real modem)
# nic0/nic1 are on the same native VLAN 1 as nic2 (the Spitz). A second modem there would share its layer-2 segment
# (two DHCP servers, one broadcast domain). This gives each modem port its own VLAN (PVID_BASE+n) and the edge a NIC
# on it. Persistent through br-addon-ports.service (re-run it after any 'ifreload -a'). nic2 and OPNsense are not touched.
cmd_ports() {
	[ "$(id -u)" = 0 ] || die "run as root"
	[ "$(guest_of "$EDGE")" = "CT br-edge" ] || die "run 'apply' first (no br-edge at CT $EDGE)"
	local i=0 p v next n
	for p in $MODEM_PORTS; do [ -e /sys/class/net/$p/device ] || die "$p is not a network port here"; [ "$p" = nic2 ] && die "nic2 carries OPNsense's WAN: not a modem port"; done
	cat >/usr/local/sbin/br-addon-ports <<EOS
#!/bin/sh
# Black Relay add-on: per-port VLANs for modem ports (written by cwwk-addon.sh ports). Idempotent.
i=0
for p in $MODEM_PORTS; do
	v=\$(($PVID_BASE + i)); i=\$((i + 1))
	[ -e /sys/class/net/\$p/master ] || continue
	bridge vlan add dev \$p vid \$v pvid untagged
	bridge vlan del dev \$p vid 1 2>/dev/null || true
done
EOS
	chmod 755 /usr/local/sbin/br-addon-ports
	cat >/etc/systemd/system/br-addon-ports.service <<'EOS'
[Unit]
Description=Black Relay add-on: per-port VLANs for the modem ports
After=networking.service
Before=pve-guests.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/br-addon-ports
[Install]
WantedBy=multi-user.target
EOS
	systemctl daemon-reload; systemctl enable -q --now br-addon-ports
	n=$(pct config "$EDGE" | grep -oE 'name=up[0-9]+' | sed 's/name=up//' | sort -n | tail -1); next=$((n + 1))
	for p in $MODEM_PORTS; do
		v=$((PVID_BASE + i)); i=$((i + 1))
		pct config "$EDGE" | grep -qE "tag=$v(,|\$)" && { echo "  $p: edge NIC for VLAN $v already there"; continue; }
		pct set "$EDGE" -net$((next + 1)) "name=up$next,bridge=$BR_UP,tag=$v,ip=manual,type=veth" &&
			echo "  $p -> VLAN $v -> edge up$next"
		next=$((next + 1))
	done
	echo "done. If the new NICs do not show inside the edge (pct exec $EDGE -- ip -br addr), run: pct reboot $EDGE"
	echo "Plug the modem in (nic1 -> VLAN 200 -> up1 ...). The edge gets an address within seconds, but only adopts a NEW uplink when the tunnel next starts:"
	echo "  pct exec $EDGE -- systemctl restart black-relay@br0     (a few seconds of blip; the minute-by-minute recheck does not add new ports)"
	echo "Then: bash cwwk-addon.sh status   (hub should show 12 paths = 6 lanes per carrier)"
}

# ------------------------------------------------------------------ status
cmd_status() {
	[ -n "$(guest_of "$EDGE")" ] || { echo "no CT $EDGE here (nothing installed)"; return 1; }
	local idx=1; [ -r $D/addon.env ] && idx=$(sed -n 's/^IDX=//p' $D/addon.env)
	say "edge (CT $EDGE)"
	pct status "$EDGE"
	pct exec "$EDGE" -- sh -c "ip -br addr | grep -E '^(tr0|up[0-9]|br0)'; echo; systemctl is-active black-relay@br0 nftables dnsmasq 2>&1 | paste -sd' '" 2>&1
	echo "  tunnel log:"; pct exec "$EDGE" -- sh -c 'journalctl -u black-relay@br0 -n 3 --no-pager 2>/dev/null | cut -c1-160' 2>&1 | sed 's/^/    /'
	echo "  hub ping over the tunnel:"
	pct exec "$EDGE" -- ping -n -c2 -W2 -I br0 "10.255.$idx.1" 2>&1 | tail -2 | sed 's/^/    /' || true
	echo "  exit address (should be the hub, 89.167.30.202):"
	pct exec "$EDGE" -- curl -s -m 8 https://ifconfig.me 2>&1 | sed 's/^/    /'; echo
	pct exec "$EDGE" -- sh -c 'command -v br-selftest >/dev/null && br-selftest 2>&1 | tail -15' 2>&1 | sed 's/^/    /' || true
}

# ------------------------------------------------------------------ rollback
cmd_rollback() {
	[ "$(id -u)" = 0 ] || die "run as root"
	g=$(guest_of "$EDGE")
	if [ -z "$g" ]; then echo "no CT $EDGE here"
	elif [ "$g" != "CT br-edge" ]; then die "guest $EDGE is '$g', not ours: refusing to remove it"
	else
		pct stop "$EDGE" 2>/dev/null || true
		pct destroy "$EDGE" --purge 1
		echo "CT $EDGE removed"
	fi
	rm -f $D/addon.env 2>/dev/null || true
	echo "kept: $D/$SITE.join (secret; delete it when the work is finished). Existing bridges, VMs and OPNsense were never touched."
	echo "hub side: the site stays registered; remove it on BR2026 only if the build is abandoned."
}

# ------------------------------------------------------------------ wifi (the Spitz's Wi-Fi onto the LAN)
# The Spitz bridges its Wi-Fi to VLAN 40 on the cable it shares with its modem LAN (nic2). Nothing here served VLAN 40, so Wi-Fi clients
# got no address. A veth pair patches VLAN 40 (vmbr10) into the LAN (vmbr1): OPNsense's own DHCP/DNS then serve Wi-Fi clients as ordinary
# LAN devices (172.22.100.x, same rules, tunnel, tailnet). VLAN 40 is then removed from nic0/nic1 (the ports that face the outside, incl. the ISP port):
# it is the LAN now, so only the Spitz trunk may feed it. Persistent (br-wifi-patch.service). OPNsense is not touched.
cmd_wifi() {
	[ "$(id -u)" = 0 ] || die "run as root"
	ip link show "$BR_UP" >/dev/null 2>&1 && ip link show "$BR_DL" >/dev/null 2>&1 || die "bridges $BR_UP / $BR_DL missing"
	cat >/usr/local/sbin/br-wifi-patch <<EOS
#!/bin/sh
# Black Relay add-on: Spitz Wi-Fi VLAN 40 onto the site LAN (written by cwwk-addon.sh wifi). Idempotent.
ip link show wifi40a >/dev/null 2>&1 || ip link add wifi40a type veth peer name wifi40b
ip link set wifi40a master $BR_UP; ip link set wifi40b master $BR_DL
ip link set wifi40a up; ip link set wifi40b up
bridge vlan add dev wifi40a vid 40 pvid untagged
bridge vlan del dev wifi40a vid 1 2>/dev/null || true
for p in nic0 nic1; do [ -e /sys/class/net/\$p/master ] && bridge vlan del dev \$p vid 40 2>/dev/null || true; done
exit 0
EOS
	chmod 755 /usr/local/sbin/br-wifi-patch
	cat >/etc/systemd/system/br-wifi-patch.service <<'EOS'
[Unit]
Description=Black Relay add-on: Spitz Wi-Fi (VLAN 40) onto the site LAN
After=networking.service br-addon-ports.service
Before=pve-guests.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/br-wifi-patch
[Install]
WantedBy=multi-user.target
EOS
	systemctl daemon-reload; systemctl enable -q --now br-wifi-patch
	echo "Wi-Fi patched onto the LAN: clients of the Spitz's SSIDs now get 172.22.100.x from OPNsense. Undo: bash cwwk-addon.sh wifi-rollback"
}

cmd_wifi_rollback() {
	[ "$(id -u)" = 0 ] || die "run as root"
	systemctl disable --now br-wifi-patch 2>/dev/null || true
	ip link del wifi40a 2>/dev/null || true
	rm -f /etc/systemd/system/br-wifi-patch.service /usr/local/sbin/br-wifi-patch; systemctl daemon-reload
	echo "Wi-Fi patch removed. VLAN 40 stays pruned from nic0/nic1 until the next 'ifreload -a' or reboot (harmless: nothing served it before)."
}

# ------------------------------------------------------------------ controller (PHASE 3)
# The same web UI cwwk01 has (health, multipath sliders, network, compute, services, setup), as CT 111 br-controller.
# NIC 1 on the site LAN (CTRL_IP) so the teams reach it over the tailnet and the LAN; NIC 2 on the transit (.3) to drive the edge
# (its forced-command SSH key, br-ctl) and to answer the hub's remote-access path. The router it reads is OPNsense (API key).
# Needs /root/.opn-api (lines key=... and secret=... for the OPNsense API; removed afterwards) and the kit's controller/ files.
cmd_controller() {
	[ "$(id -u)" = 0 ] || die "run as root"
	[ "$(guest_of "$EDGE")" = "CT br-edge" ] || die "run 'apply' first (no br-edge at CT $EDGE)"
	[ -z "$(guest_of "$CTRL")" ] || die "guest ID $CTRL exists: nothing to do (see: pct config $CTRL; 'controller-rollback' removes it)"
	[ -r $D/addon.env ] && . $D/addon.env
	local C=$KIT/controller OPN=/root/.opn-api f CA=${CTRL_IP%/*} PVE_ADDR W pub hk apw
	for f in app.py index.html status.html br-controller.service br-controller-network.conf; do [ -s "$C/$f" ] || die "controller file missing from the kit: $C/$f"; done
	[ -s "$OPN" ] || die "OPNsense API file $OPN missing (two lines: key=... and secret=...)"
	ping -c1 -W2 "$CA" >/dev/null 2>&1 && die "$CA already answers: pick another with CTRL_IP=ADDRESS/24"
	PVE_ADDR=$(ip -4 -o addr show "$BR_DL" | sed -n 's/.* inet \([0-9.]*\)\/.*/\1/p' | head -1); [ -n "$PVE_ADDR" ] || die "no address on $BR_DL"
	mkdir -p $D; chmod 700 $D

	say "1/6 controller container (CT $CTRL)"
	pct create "$CTRL" local:vztmpl/$TPL --hostname br-controller --cores 1 --memory 512 --swap 256 \
		--rootfs "$STORE:4" --unprivileged 1 --features nesting=1 --onboot 1 --startup order=3 \
		--nameserver "$DL_DNS" --searchdomain lan --ostype debian \
		-net0 "name=eth0,bridge=$BR_DL,ip=$CTRL_IP,gw=$CTRL_GW,type=veth" \
		-net1 "name=tr0,bridge=$BR_TRANSIT,ip=$TRANSIT.3/$TLEN,type=veth" \
		--description "Black Relay controller ($SITE): health, multipath, network, compute, services. https://$CA. Added by cwwk-addon.sh controller" >/dev/null
	pct start "$CTRL"; wait_ct "$CTRL"
	for _ in $(seq 1 20); do pct exec "$CTRL" -- getent hosts deb.debian.org >/dev/null 2>&1 && break; sleep 2; done
	pct exec "$CTRL" -- getent hosts deb.debian.org >/dev/null 2>&1 ||
		die "the controller has no internet through $CTRL_GW (OPNsense, then the tunnel). Only CT $CTRL was added; 'controller-rollback' removes it"
	pct exec "$CTRL" -- sh -c 'apt-get update -q >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -y -q python3 openssh-client ca-certificates >/dev/null'

	say "2/6 controller files for $SITE"
	W=$(mktemp -d); cp "$C"/app.py "$C"/index.html "$C"/status.html "$C"/br-controller.service "$W/"
	# cwwk01's addresses -> this site (longest first): controller, Proxmox host, router, services, TAK, ranges, tunnel peer, remote-access path
	sed -i -E \
		-e "s#\b10\.40\.0\.10\b#$CA#g" -e "s#\b10\.40\.0\.2\b#$PVE_ADDR#g" -e "s#\b10\.40\.0\.1\b#$OPN_HOST#g" \
		-e "s#\b10\.41\.0\.20\b#$SVC_VM#g" -e "s#\b10\.41\.0\.30\b#$TAK_VM#g" \
		-e "s#\b10\.40\.0\.0/24#${PVE_ADDR%.*}.0/24#g" -e "s#\b10\.41\.0\.0/24#${SVC_VM%.*}.0/24#g" \
		-e "s#\b10\.39\.0\.1\b#$TRANSIT.1#g" -e "s#\b10\.39\.0\.2\b#$TRANSIT.2#g" -e "s#\b10\.255\.1\.1\b#10.255.$IDX.1#g" \
		-e "s#\b10\.40\.0\.#${PVE_ADDR%.*}.#g" -e "s#\b10\.41\.0\.#${SVC_VM%.*}.#g" \
		-e "s#headscale\.l8s\.dev/cwwk/#headscale.l8s.dev/cwwk$N/#g" \
		"$W/app.py" "$W/index.html" "$W/status.html" "$W/br-controller.service"
	if grep -nE '10\.(39|40|41)\.0\.|10\.255\.1\.' "$W/app.py" "$W/index.html" "$W/status.html" "$W/br-controller.service"; then
		die "cwwk01 addresses left in the rendered controller (render bug); CT $CTRL left for inspection"; fi
	python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$W/app.py" || die "rendered app.py does not parse"
	pct exec "$CTRL" -- sh -c 'mkdir -p /opt/br-controller /etc/br-controller /etc/systemd/system/br-controller.service.d; chmod 700 /etc/br-controller'
	for f in app.py index.html status.html; do pct push "$CTRL" "$W/$f" /opt/br-controller/$f --perms 0644; done
	pct push "$CTRL" "$W/br-controller.service" /etc/systemd/system/br-controller.service --perms 0644
	pct push "$CTRL" "$C/br-controller-network.conf" /etc/systemd/system/br-controller.service.d/10-network.conf --perms 0644
	rm -rf "$W"
	# the hub's tunnel address is reached through the edge (remote-access gateway answers the hub from here)
	cat >$D/.routes.service <<EOS
[Unit]
Description=Route to the hub's tunnel address via the edge (so the remote-access gateway can answer)
After=network-online.target
Before=br-controller.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'for i in \$(seq 1 30); do ip route replace 10.255.$IDX.0/30 via $TRANSIT.1 dev tr0 && exit 0; sleep 1; done; echo gave up after 30s >&2; exit 1'
[Install]
WantedBy=multi-user.target
EOS
	pct push "$CTRL" $D/.routes.service /etc/systemd/system/br-controller-routes.service --perms 0644; rm -f $D/.routes.service

	say "3/6 its certificate, and its key to the edge (only the br-ctl commands, only from the controller)"
	openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 1825 -subj /CN=controller.lan \
		-addext "subjectAltName=DNS:controller.lan,DNS:status.lan,DNS:br-controller,DNS:br-controller.lan,IP:$CA,IP:$TRANSIT.3" \
		-keyout $D/.ctl.key -out $D/controller-tls.crt 2>/dev/null
	pct push "$CTRL" $D/controller-tls.crt /etc/br-controller/tls.crt --perms 0600
	pct push "$CTRL" $D/.ctl.key /etc/br-controller/tls.key --perms 0600; shred -u $D/.ctl.key 2>/dev/null || rm -f $D/.ctl.key
	pct push "$CTRL" /etc/pve/pve-root-ca.pem /etc/br-controller/pve-ca.pem --perms 0600
	pct exec "$CTRL" -- sh -c 'mkdir -p /root/.ssh && chmod 700 /root/.ssh && [ -f /root/.ssh/id_edge_ctl ] || ssh-keygen -q -t ed25519 -N "" -C br-controller -f /root/.ssh/id_edge_ctl'
	pub=$(pct exec "$CTRL" -- cat /root/.ssh/id_edge_ctl.pub)
	printf 'from="%s",command="/usr/local/sbin/br-ctl",restrict %s\n' "$TRANSIT.3" "$pub" |
		pct exec "$EDGE" -- sh -c 'mkdir -p /root/.ssh; chmod 700 /root/.ssh; touch /root/.ssh/authorized_keys; grep -v " br-controller$" /root/.ssh/authorized_keys >/root/.ssh/ak.new || true; cat >>/root/.ssh/ak.new; mv /root/.ssh/ak.new /root/.ssh/authorized_keys; chmod 600 /root/.ssh/authorized_keys'
	hk=$(pct exec "$EDGE" -- cat /etc/ssh/ssh_host_ed25519_key.pub | awk '{print $1, $2}')
	echo "$TRANSIT.1 $hk" | pct exec "$CTRL" -- sh -c 'cat > /root/.ssh/known_hosts; chmod 600 /root/.ssh/known_hosts'
	# The hub serves its access list (:8099) only to the site tunnel's own address and drops a device behind the edge, the controller included
	# (cwwk01's controller shows the same: cache from 2026-11-07). Without it nobody may sign in ("not allowed"). Rewrite just that flow at the edge.
	cat >$D/.idsnat.sh <<EOS
cp -p /etc/nftables.conf /etc/nftables.conf.bak-pre-idsnat
awk '/modem_admin masquerade/ && !d {print; print "\t\t# controller -> hub access list (:8099): the hub only answers the tunnel address"; print "\t\toifname \"br0\" ip saddr $TRANSIT.3 ip daddr 10.255.$IDX.1 tcp dport 8099 snat ip to 10.255.$IDX.2"; d=1; next} {print}' /etc/nftables.conf.bak-pre-idsnat >/etc/nftables.conf
nft -c -f /etc/nftables.conf
nft list chain inet edge postrouting | grep -q 'dport 8099' || nft add rule inet edge postrouting oifname br0 ip saddr $TRANSIT.3 ip daddr 10.255.$IDX.1 tcp dport 8099 snat ip to 10.255.$IDX.2
EOS
	pct exec "$EDGE" -- sh -c 'cat >/tmp/idsnat.sh' <$D/.idsnat.sh; rm -f $D/.idsnat.sh
	pct exec "$EDGE" -- sh -e /tmp/idsnat.sh || die "could not add the access-list rule on the edge (restore /etc/nftables.conf.bak-pre-idsnat)"
	pct exec "$EDGE" -- rm -f /tmp/idsnat.sh

	say "4/6 Proxmox API token (read + power only)"
	pveum role list --output-format json | grep -q '"BlackRelayController"' || pveum role add BlackRelayController -privs "Datastore.Audit,Sys.Audit,VM.Audit,VM.PowerMgmt"
	pveum user list --output-format json | grep -q '"br-controller@pve"' || pveum user add br-controller@pve --comment "Black Relay controller (API token only)"
	pveum acl modify / --users br-controller@pve --roles BlackRelayController
	pveum user token remove br-controller@pve ui >/dev/null 2>&1 || true
	pveum user token add br-controller@pve ui --privsep 1 --output-format json >$D/pve-token.json
	pveum acl modify / --tokens 'br-controller@pve!ui' --roles BlackRelayController

	say "5/6 controller settings"
	apw=$(head -c 18 /dev/urandom | base64 | tr -d '+/=' | cut -c1-16)
	( umask 077; printf '%s\n' "$apw" >$D/controller-admin.pw ); unset apw
	python3 - "$D/pve-token.json" "$OPN" "$D/.config.json" "$D/controller-admin.pw" "$SITE" "$N" "$IDX" "$PVE_ADDR" "$OPN_HOST" "$TRANSIT" "$SVC_VM" "$TAK_VM" "$(hostname)" "$CTRL" "$EDGE" <<'PY'
import base64, hashlib, json, os, sys
tok, opn, out, pwf, site, n, idx, pve, opnh, T, svc, tak, node, ctrl, edge = sys.argv[1:16]
kv = dict(l.strip().split("=", 1) for l in open(opn) if "=" in l)
apw = open(pwf).read().strip()
salt = os.urandom(16)
c = {
    "listen": "0.0.0.0", "port": 443, "tls_cert": "/etc/br-controller/tls.crt", "tls_key": "/etc/br-controller/tls.key",
    "admin_hash": "pbkdf2$" + base64.b64encode(salt).decode() + "$" + base64.b64encode(hashlib.pbkdf2_hmac("sha256", apw.encode(), salt, 310000)).decode(),
    "proxmox": {"host": pve, "port": 8006, "node": node, "token_id": "br-controller@pve!ui",
                "token_secret": json.load(open(tok))["value"], "cafile": "/etc/br-controller/pve-ca.pem"},
    "router": {"kind": "opnsense", "host": opnh, "key": kv["key"], "secret": kv["secret"], "insecure": True},
    "edge": {"host": T + ".1", "dash_port": 8088, "key": "/root/.ssh/id_edge_ctl"},
    "required_guests": [100, 101, 102, int(edge), int(ctrl)],
    "protected_guests": [100, int(edge), int(ctrl)],
    "services": [
        {"id": "tak", "name": "TAK Server", "kind": "tak", "url": "https://%s:8446/" % tak, "health_url": "tls://%s:8089" % tak, "deployed": True,
         "description": "TAK Server: clients connect on 8089 (TLS, client certificate); admin and enrolment on 8446; API on 8443."},
        {"id": "rf-console", "name": "RF Console", "kind": "sensors", "url": "http://%s:8080/" % svc, "health_url": "http://%s:8080/" % svc, "deployed": True,
         "description": "RF detection: the WBT Console (live RF map, nodes, alerts)."},
        {"id": "mqtt", "name": "MQTT broker", "kind": "sensors", "url": "", "health_url": "tcp://%s:1883" % svc, "deployed": True,
         "description": "Sensor messages (port 1883, needs a login)."},
        {"id": "video", "name": "Video (RTSP)", "kind": "sensors", "url": "", "health_url": "rtsp://%s:8554/" % svc, "deployed": True,
         "description": "RTSP video server (port 8554)."},
    ],
    "admin_groups": ["survivability"], "viewer_groups": ["headscale-users"],
    "sso_proxy": pve, "gateway_listen": T + ".3", "gateway_port": 8444, "gateway_peer": "10.255.%s.1" % idx,
    "identity_url": "http://10.255.%s.1:8099/identity.json" % idx,
    "gateway_base": "/cwwk%s" % n, "public_url": "https://headscale.l8s.dev/cwwk%s" % n,
    "legacy_sso": False, "site": site, "switches": [],
}
fd = os.open(out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600); os.write(fd, json.dumps(c, indent=2).encode()); os.close(fd)
PY
	pct push "$CTRL" $D/.config.json /etc/br-controller/config.json --perms 0600
	shred -u $D/.config.json 2>/dev/null || rm -f $D/.config.json; rm -f $D/pve-token.json "$OPN"

	say "6/6 start"
	pct exec "$CTRL" -- sh -c 'systemctl daemon-reload; systemctl enable -q --now br-controller-routes br-controller'
	sleep 6
	pct exec "$CTRL" -- systemctl is-active -q br-controller || die "controller did not start (pct exec $CTRL -- journalctl -u br-controller)"
	curl -sk -m 10 -o /dev/null -w "  https://$CA/ -> http %{http_code}\n" "https://$CA/" || true
	cat <<EOF

Controller done: https://$CA  (site LAN and tailnet)
  admin password (break-glass, on site): $D/controller-admin.pw on this host (mode 600). Not printed here.
  remote access for the teams (Pocket ID) still needs: the hub path + a Pocket ID client for /cwwk$N/ (see README).
  undo: bash cwwk-addon.sh controller-rollback
EOF
}

cmd_controller_oidc() {
	[ "$(id -u)" = 0 ] || die "run as root"
	[ "$(guest_of "$CTRL")" = "CT br-controller" ] || die "no br-controller at CT $CTRL (run 'controller' first)"
	[ -r $D/addon.env ] && . $D/addon.env
	local cid csec
	if [ -t 0 ]; then read -rp "Pocket ID client ID: " cid; read -rsp "Pocket ID client secret (input hidden): " csec; echo
	else read -r cid; read -r csec; fi
	[[ "$cid" =~ ^[A-Za-z0-9._-]{8,128}$ ]] || die "client ID looks wrong"
	[ ${#csec} -ge 16 ] || die "client secret looks too short"
	printf '%s\n%s\n' "$cid" "$csec" | pct exec "$CTRL" -- python3 -c '
import json, os, sys
cid, sec = sys.stdin.read().split("\n")[:2]
p = "/etc/br-controller/config.json"; c = json.load(open(p))
c["oidc"] = {"issuer": "https://id.l8s.dev", "client_id": cid.strip(), "client_secret": sec.strip()}
t = p + ".tmp"; fd = os.open(t, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
os.write(fd, json.dumps(c, indent=2).encode()); os.close(fd); os.replace(t, p)'
	unset csec
	pct exec "$CTRL" -- systemctl restart br-controller
	echo "saved; controller restarted. Sign in at https://headscale.l8s.dev/cwwk$N/"
}

cmd_controller_rollback() {
	[ "$(id -u)" = 0 ] || die "run as root"
	local g; g=$(guest_of "$CTRL")
	if [ -z "$g" ]; then echo "no CT $CTRL here"
	elif [ "$g" != "CT br-controller" ]; then die "guest $CTRL is '$g', not ours: refusing to remove it"
	else pct stop "$CTRL" 2>/dev/null || true; pct destroy "$CTRL" --purge 1; echo "CT $CTRL removed"; fi
	pveum user token remove br-controller@pve ui >/dev/null 2>&1 || true
	pveum user delete br-controller@pve >/dev/null 2>&1 || true
	pct exec "$EDGE" -- sh -c 'grep -v " br-controller$" /root/.ssh/authorized_keys >/root/.ssh/ak.new 2>/dev/null; mv /root/.ssh/ak.new /root/.ssh/authorized_keys' 2>/dev/null || true
	echo "kept: $D/controller-admin.pw (delete it if the controller is gone for good). The edge, OPNsense and the VMs were never touched."
}

case "${1:-}" in
	survey)   cmd_survey ;;
	render)   [ $# -eq 4 ] || die "usage: render SRC_EDGE_TREE OUT_DIR TUNNEL_INDEX"; mkdir -p "$3"; render_edge "$2" "$3" "$4"; echo "rendered into $3" ;;
	plan)     cmd_plan ;;
	apply)    cmd_apply "${2:-}" ;;
	status)   cmd_status ;;
	ports)    cmd_ports ;;
	rollback) cmd_rollback ;;
	wifi) cmd_wifi ;;
	wifi-rollback) cmd_wifi_rollback ;;
	controller) cmd_controller ;;
	controller-oidc) cmd_controller_oidc ;;
	controller-rollback) cmd_controller_rollback ;;
	*) sed -n '2,18p' "${BASH_SOURCE[0]:-$0}" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
