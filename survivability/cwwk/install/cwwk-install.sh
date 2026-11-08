#!/bin/bash
# cwwk-install.sh: turn a fresh Proxmox VE 9 CWWK into Black Relay site N, the same
# build as cwwk01. Run as root on the new box, from the unpacked kit (make-kit.sh).
#
#   bash cwwk-install.sh plan N              show the site's addresses, change nothing
#   bash cwwk-install.sh install N JOINFILE  host packages, bridges, br-edge / br-router /
#                                            br-controller, keys, host tools. The box keeps
#                                            its install network (vmbr0) and nothing is cabled.
#   bash cwwk-install.sh ports               every port joins the port bridge (any cable,
#                                            any port). Ends the install network. Undoes
#                                            itself after 15 minutes unless confirmed.
#   bash cwwk-install.sh finish              once modems are in: tunnel check, tailnet,
#                                            self-test, keep the port layout.
#   bash cwwk-install.sh check               state of everything
#
# Then, as on cwwk01: br-vault-init (USB stick in; site lock), br-controller-oidc
# (Pocket ID), spitz-setup.sh (Wi-Fi on the site LAN). See README.md.
#
# Address plan, site N (inside 10.32.0.0/11), o = 8(N-1):
#   transit 10.(39+o).0.0/30   edge .1, router .2
#   LAN     10.(40+o).0.0/24   router .1, Proxmox host .2, controller .10, DHCP .100-.199
#   services 10.(41+o).0.0/24  router .1
#   tunnel  10.255.X.2/30      X = the hub's index for the site (from the join token)
set -euo pipefail
KIT=$(cd "$(dirname "$0")" && pwd)
D=/root/black-relay; ST=$D/install.env
EDGE=101 ROUTER=102 CTRL=103 BASE=100
TPL=debian-13-standard_13.6-1_amd64.tar.zst
umask 077

say() { printf '\n== %s\n' "$*"; }
die() { echo "STOP: $*" >&2; exit 1; }
phys() { for d in /sys/class/net/*/device; do n=${d%/device}; n=${n##*/}; [ -e /sys/class/net/$n/wireless ] || echo $n; done | sort -V; }

plan() {
	N=$1; [[ "$N" =~ ^[2-9]$ ]] || die "site number must be 2-9 (cwwk01 is site 1)"
	O=$((8 * (N - 1)))
	SITE=cwwk$(printf %02d "$N")
	T=10.$((39 + O)).0 L=10.$((40 + O)).0 S=10.$((41 + O)).0
}

load() { [ -r $ST ] || die "run install first"; . $ST; plan "$N"; }

# cwwk01's files -> this site: its addresses, tunnel index and name
render() {
	sed -i -E -e "s/\b10\.39\.0\./$T./g" -e "s/\b10\.40\.0\./$L./g" -e "s/\b10\.41\.0\./$S./g" \
		-e "s/\b10\.255\.1\.([12])\b/10.255.$IDX.\1/g" -e "s/cwwk-node01/cwwk-node$(printf %02d "$N")/g" \
		-e "s/\bcwwk01\b/$SITE/g" "$@"
}

ct_push() { # ct src dest mode
	pct push "$1" "$2" "$3" --perms "${4:-0644}"
}

wait_ct() { # ct: until it answers
	for _ in $(seq 1 30); do pct exec "$1" -- true 2>/dev/null && return 0; sleep 1; done
	die "container $1 did not start"
}

# ------------------------------------------------------------------ plan
cmd_plan() {
	plan "$1"
	cat <<EOF
site $SITE (number $N)
  transit   $T.0/30   br-edge $T.1, br-router $T.2
  LAN       $L.0/24   br-router $L.1, Proxmox $L.2, controller https://$L.10, DHCP .100-.199
  services  $S.0/24   br-router $S.1
  ports     $(phys | tr '\n' ' ')
  hub       sudo bash hub-add-site.sh $N   (on BR2026; makes the join file)
EOF
}

# ------------------------------------------------------------------ install
cmd_install() {
	plan "$1"; J=${2:-}
	[ "$(id -u)" = 0 ] || die "run as root"
	command -v pct >/dev/null || die "this is not a Proxmox host"
	[ -r "$J" ] || die "join file missing (made on BR2026 by hub-add-site.sh)"
	( cd "$KIT" && sha256sum -c --quiet SHA256SUMS ) || die "kit files damaged (SHA256SUMS)"
	. "$J"
	[ "${SITE:-}" = "cwwk$(printf %02d "$1")" ] || die "join file is for ${SITE:-?}, not site $1"
	plan "$1"
	IDX=$(printf '%s' "${JOIN_TOKEN#brj1.}" | base64 -d | sed -n 's#^BR_TUN=10\.255\.\([0-9]*\)\.2/30$#\1#p')
	[ -n "$IDX" ] || die "join token unreadable"
	for id in $EDGE $ROUTER $CTRL; do pct status $id >/dev/null 2>&1 && die "container $id already exists: this box is not fresh"; done
	ip -4 route show default | grep -q . || die "no internet route: connect the install network first"
	mapfile -t P < <(phys); [ ${#P[@]} -ge 2 ] || die "found ${#P[@]} network ports, need 2 or more"
	HN=$(hostname -s)
	mkdir -p $D; chmod 700 $D
	printf 'N=%s\nIDX=%s\nHN=%s\nPORTS="%s"\n' "$N" "$IDX" "$HN" "${P[*]}" >$ST
	install -m 0600 "$J" $D/$SITE.join

	say "1/7 host packages"
	for f in /etc/apt/sources.list.d/pve-enterprise.sources /etc/apt/sources.list.d/ceph.sources; do
		if [ -f "$f" ] && ! grep -q '^Enabled: no' "$f"; then echo 'Enabled: no' >>"$f"; fi
	done
	cat >/etc/apt/sources.list.d/proxmox.sources <<'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
	chmod 644 /etc/apt/sources.list.d/proxmox.sources
	if [ ! -f /usr/share/keyrings/tailscale-archive-keyring.gpg ]; then
		curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg -o /usr/share/keyrings/tailscale-archive-keyring.gpg
		echo "deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/debian trixie main" \
			>/etc/apt/sources.list.d/tailscale.list
		chmod 644 /usr/share/keyrings/tailscale-archive-keyring.gpg /etc/apt/sources.list.d/tailscale.list
	fi
	apt-get update -q >/dev/null
	DEBIAN_FRONTEND=noninteractive apt-get install -y -q tailscale cryptsetup-bin gdisk dosfstools socat openssl python3 >/dev/null
	install -m 0644 "$KIT/host/90-black-relay.conf" /etc/sysctl.d/90-black-relay.conf; sysctl -q --system
	install -m 0644 "$KIT/templates/$TPL" /var/lib/vz/template/cache/$TPL
	install -m 0644 "$KIT/templates/br-router-rootfs.tar.xz" /var/lib/vz/template/cache/br-router-rootfs.tar.xz

	say "2/7 internal bridges (no cables involved; vmbr0 stays as it is)"
	if ! grep -q '^auto vmbr10' /etc/network/interfaces; then
		cp -p /etc/network/interfaces $D/interfaces.before-install
		cat >>/etc/network/interfaces <<EOF

auto vmbr1
iface vmbr1 inet static
	address $L.2/24
	bridge-ports none
	bridge-stp off
	bridge-fd 0

auto vmbr2
iface vmbr2 inet manual
	post-up echo 1 > /proc/sys/net/ipv6/conf/\$IFACE/disable_ipv6
	bridge-ports none
	bridge-stp off
	bridge-fd 0

auto vmbr3
iface vmbr3 inet manual
	post-up echo 1 > /proc/sys/net/ipv6/conf/\$IFACE/disable_ipv6
	bridge-ports none
	bridge-stp off
	bridge-fd 0

auto vmbr10
iface vmbr10 inet manual
	post-up echo 1 > /proc/sys/net/ipv6/conf/\$IFACE/disable_ipv6
	bridge-ports none
	bridge-stp on
	bridge-bridgeprio 0
	bridge-maxage 6
	bridge-fd 4
	bridge-vlan-aware yes
	bridge-vids 40 41 $BASE-$((BASE + ${#P[@]} - 1))
EOF
		ifreload -a
	fi
	ip -4 route show default | grep -q . || die "internet route lost after adding bridges (backup: $D/interfaces.before-install)"

	say "3/7 br-edge (CT $EDGE): multipath tunnel"
	nets=(-net0 "name=tr0,bridge=vmbr2,ip=$T.1/30,type=veth" -net9 "name=eth9,bridge=vmbr0,ip=dhcp,type=veth")
	for i in "${!P[@]}"; do nets+=(-net$((i + 1)) "name=up$i,bridge=vmbr10,tag=$((BASE + i)),ip=manual,type=veth"); done
	pct create $EDGE local:vztmpl/$TPL --hostname br-edge --cores 2 --memory 1024 --swap 256 \
		--rootfs local-lvm:8 --unprivileged 1 --features nesting=1 --onboot 1 --startup order=1 \
		--nameserver 1.1.1.1 --searchdomain lan --ostype debian "${nets[@]}" \
		--description "Black Relay site edge: bonded tunnel to BR2026 hub ($SITE), LAN router $L.1" >/dev/null
	pct set $EDGE -dev0 /dev/net/tun
	pct start $EDGE; wait_ct $EDGE
	for _ in $(seq 1 20); do pct exec $EDGE -- getent hosts deb.debian.org >/dev/null 2>&1 && break; sleep 2; done
	pct exec $EDGE -- sh -c 'apt-get update -q >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -y -q dnsmasq nftables sshpass curl python3 >/dev/null'
	ct_push $EDGE "$KIT/pkgs/black-relay-glorytun_0.3.4+br6_amd64.deb" /root/br.deb
	pct exec $EDGE -- sh -c 'DEBIAN_FRONTEND=noninteractive apt-get install -y -q /root/br.deb >/dev/null && rm /root/br.deb'
	tar -xzf "$KIT/pkgs/wstunnel_11.1.0_linux_amd64.tar.gz" -C $D wstunnel
	ct_push $EDGE $D/wstunnel /usr/local/bin/wstunnel 0755; rm $D/wstunnel
	# cwwk01's edge files, made this site's
	W=$(mktemp -d); cp -a "$KIT/edge/." "$W/"
	for i in "${!P[@]}"; do
		[ -f "$W/etc/systemd/network/20-up$i.network" ] ||
			sed "s/up0/up$i/g; s/nic0/nic$i/g" "$W/etc/systemd/network/20-up0.network" >"$W/etc/systemd/network/20-up$i.network"
	done
	find "$W/etc" "$W/usr" -type f -print0 | while IFS= read -r -d '' f; do render "$f"; done
	python3 - "$W/etc/black-relay/dash.json" "$SITE" "${#P[@]}" <<'PY'
import json, sys
p, site, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
c = json.load(open(p)); c["site"] = site
c["lanes"] = {f"up{i}": "empty port" for i in range(n)}
json.dump(c, open(p, "w"), indent=2)
PY
	( cd "$W" && find etc usr -type f ) | while read -r f; do
		m=0644; case "$f" in usr/local/sbin/*) m=0755 ;; esac
		pct exec $EDGE -- mkdir -p "/$(dirname "$f")"
		ct_push $EDGE "$W/$f" "/$f" $m
	done
	rm -rf "$W"
	# join the hub (writes br0.conf + the site key), then the HTTPS lanes
	pct exec $EDGE -- black-relay-setup join "$JOIN_TOKEN" --no-start >/dev/null
	{ echo; cat "$KIT/edge/br0.wss.conf"; echo "WSS_PREFIX=$WSS_PREFIX"; } >$D/.wss
	pct exec $EDGE -- sh -c 'cat >> /etc/black-relay/br0.conf; chmod 600 /etc/black-relay/br0.conf' <$D/.wss
	shred -u $D/.wss
	pct exec $EDGE -- sh -c 'systemctl daemon-reload
		systemctl enable -q systemd-networkd nftables dnsmasq br-dash br-edge-routes br-lane-nurse br-watchdog br-uplinks-recheck.timer black-relay@br0 black-relay-watch@br0
		nft -c -f /etc/nftables.conf'
	pct shutdown $EDGE
	pct set $EDGE -delete net9
	pct set $EDGE -nameserver 127.0.0.1

	say "4/7 br-router (CT $ROUTER): OpenWrt, DHCP/DNS/firewall"
	pct create $ROUTER local:vztmpl/br-router-rootfs.tar.xz --hostname br-router --cores 1 --memory 256 --swap 0 \
		--rootfs local-lvm:1 --unprivileged 1 --ostype unmanaged --arch amd64 --onboot 1 --startup order=2 \
		-net0 name=eth0,bridge=vmbr1,type=veth -net1 name=eth1,bridge=vmbr2,type=veth -net2 name=eth2,bridge=vmbr3,type=veth \
		-net4 name=eth4,bridge=vmbr10,tag=40,type=veth -net5 name=eth5,bridge=vmbr10,tag=41,type=veth \
		--description "Black Relay site router (OpenWrt + LuCI): LAN $L.1, services $S.1, uplink $T.2 -> br-edge ($SITE)" >/dev/null
	pct start $ROUTER; wait_ct $ROUTER
	# new identity: no password until set below, own SSH host keys and HTTPS certificate on first start
	pct exec $ROUTER -- sh -c 'awk -F: "{print \$1\":*:0:0:99999:7:::\"}" /etc/passwd > /etc/shadow; chmod 600 /etc/shadow
		mkdir -p /etc/dropbear; chmod 700 /etc/dropbear'
	pct exec $ROUTER -- sh -c "cd /etc/config && sed -i -e 's/10\\.39\\.0\\./$T./g' -e 's/10\\.40\\.0\\./$L./g' -e 's/10\\.41\\.0\\./$S./g' \
		-e \"s/'10\\.255\\.1\\.1'/'10.255.$IDX.1'/g\" network firewall dhcp uhttpd
		uci -q delete network.globals.dhcp_default_duid; uci commit network"
	pw=$(head -c 24 /dev/urandom | base64 | tr -d '+/=' | cut -c1-24)
	printf '%s\n%s\n' "$pw" "$pw" | pct exec $ROUTER -- passwd root >/dev/null 2>&1
	printf '%s\n' "$pw" >$D/router-root.pw; unset pw
	pct exec $ROUTER -- sh -c 'rm -f /etc/uhttpd.crt /etc/uhttpd.key; /etc/init.d/dropbear restart; /etc/init.d/network restart; sleep 3
		/etc/init.d/firewall restart; /etc/init.d/dnsmasq restart; /etc/init.d/uhttpd restart' >/dev/null 2>&1
	for _ in $(seq 1 20); do pct exec $ROUTER -- test -s /etc/uhttpd.crt && break; sleep 1; done
	pct exec $ROUTER -- cat /etc/uhttpd.crt >$D/.router.crt || die "router has no HTTPS certificate"
	# px5g writes DER; the controller pins it as PEM
	openssl x509 -inform DER -in $D/.router.crt -out $D/router.pem 2>/dev/null ||
		openssl x509 -in $D/.router.crt -out $D/router.pem || die "router certificate unreadable"
	rm -f $D/.router.crt

	say "5/7 br-controller (CT $CTRL): web UI"
	pct create $CTRL local:vztmpl/$TPL --hostname br-controller --cores 1 --memory 512 --swap 256 \
		--rootfs local-lvm:4 --unprivileged 1 --features nesting=1 --onboot 1 --startup order=3 \
		--nameserver $L.1 --searchdomain lan --ostype debian \
		-net0 "name=eth0,bridge=vmbr1,ip=$L.10/24,gw=$L.1,type=veth" \
		--description "Black Relay CWWK controller ($SITE): health, multipath, network, Wi-Fi, compute, services. https://$L.10" >/dev/null
	pct start $CTRL; wait_ct $CTRL
	pct exec $CTRL -- mkdir -p /opt/br-controller /etc/br-controller /etc/systemd/system/br-controller.service.d
	pct exec $CTRL -- chmod 700 /etc/br-controller
	W=$(mktemp -d); cp "$KIT"/controller/{app.py,index.html,status.html,br-controller.service} "$W/"
	render "$W"/*
	for f in app.py index.html status.html; do ct_push $CTRL "$W/$f" /opt/br-controller/$f; done
	ct_push $CTRL "$W/br-controller.service" /etc/systemd/system/br-controller.service
	ct_push $CTRL "$KIT/controller/br-controller-network.conf" /etc/systemd/system/br-controller.service.d/10-network.conf
	rm -rf "$W"
	# its HTTPS certificate (also pinned by BR2026 for remote access)
	openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 1825 -subj /CN=controller.lan \
		-addext "subjectAltName=DNS:controller.lan,DNS:status.lan,DNS:br-controller,DNS:br-controller.lan,IP:$L.10" \
		-keyout $D/.ctl.key -out $D/controller-tls.crt 2>/dev/null
	ct_push $CTRL $D/controller-tls.crt /etc/br-controller/tls.crt 0600
	ct_push $CTRL $D/.ctl.key /etc/br-controller/tls.key 0600; shred -u $D/.ctl.key
	ct_push $CTRL /etc/pve/pve-root-ca.pem /etc/br-controller/pve-ca.pem 0600
	ct_push $CTRL $D/router.pem /etc/br-controller/router.pem 0600
	# its key to br-edge: only the br-ctl verbs, only from the controller
	pct exec $CTRL -- sh -c 'mkdir -p /root/.ssh && chmod 700 /root/.ssh && [ -f /root/.ssh/id_edge_ctl ] || ssh-keygen -q -t ed25519 -N "" -C br-controller -f /root/.ssh/id_edge_ctl'
	pub=$(pct exec $CTRL -- cat /root/.ssh/id_edge_ctl.pub)
	pct start $EDGE; wait_ct $EDGE
	printf 'from="%s",command="/usr/local/sbin/br-ctl",restrict %s\n' "$L.10" "$pub" |
		pct exec $EDGE -- sh -c 'mkdir -p /root/.ssh; chmod 700 /root/.ssh; cat > /root/.ssh/authorized_keys; chmod 600 /root/.ssh/authorized_keys'
	hk=$(pct exec $EDGE -- cat /etc/ssh/ssh_host_ed25519_key.pub | awk '{print $1, $2}')
	echo "$T.1 $hk" | pct exec $CTRL -- sh -c 'cat > /root/.ssh/known_hosts; chmod 600 /root/.ssh/known_hosts'

	say "6/7 Proxmox access for the controller, site lock service, host tools"
	pveum role list --output-format json | grep -q '"BlackRelayController"' ||
		pveum role add BlackRelayController -privs "Datastore.Audit,Sys.Audit,VM.Audit,VM.PowerMgmt"
	pveum user list --output-format json | grep -q '"br-controller@pve"' || pveum user add br-controller@pve --comment "Black Relay controller (API token only)"
	pveum acl modify / --users br-controller@pve --roles BlackRelayController
	pveum user token remove br-controller@pve ui >/dev/null 2>&1 || true
	pveum user token add br-controller@pve ui --privsep 1 --output-format json >$D/pve-token.json
	pveum acl modify / --tokens 'br-controller@pve!ui' --roles BlackRelayController
	W=$(mktemp -d); cp "$KIT"/host/* "$W/"; render "$W"/*
	for f in br-port-roles br-port-layout br-hostinfo br-lockd br-vault-init br-port-lock br-controller-oidc br-rotate-secrets; do
		install -m 0755 "$W/$f" /usr/local/sbin/$f
	done
	for f in br-port-roles.service br-hostinfo.service br-lockd.service br-port-lock.service; do
		install -m 0644 "$W/$f" /etc/systemd/system/$f
	done
	rm -rf "$W"
	sed -i "s#https://headscale.l8s.dev/cwwk/#https://headscale.l8s.dev/cwwk$N/#g" /usr/local/sbin/br-controller-oidc
	mkdir -p /etc/br-lockd; chmod 700 /etc/br-lockd
	printf '{\n  "site": "%s",\n  "controller": "%s",\n  "listen": ["%s", 8092]\n}\n' "$SITE" "$L.10" "$L.2" >/etc/br-lockd/config.json
	[ -s /etc/br-lockd/token ] || openssl rand -hex 32 | tr -d '\n' >/etc/br-lockd/token
	[ -s /etc/br-lockd/key.pem ] || openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
		-subj /CN=br-lockd -addext "subjectAltName=IP:$L.2" -keyout /etc/br-lockd/key.pem -out /etc/br-lockd/cert.pem 2>/dev/null
	chmod 600 /etc/br-lockd/token /etc/br-lockd/key.pem; chmod 644 /etc/br-lockd/cert.pem
	ct_push $CTRL /etc/br-lockd/cert.pem /etc/br-controller/lockd.pem 0644
	systemctl daemon-reload
	systemctl enable -q --now br-hostinfo br-lockd br-port-lock
	systemctl enable -q br-port-roles   # starts with the port layout

	say "7/7 controller settings"
	apw=$(head -c 18 /dev/urandom | base64 | tr -d '+/=' | cut -c1-16)
	printf '%s\n' "$apw" >$D/controller-admin.pw
	{ printf '%s\n' "$apw"; cat $D/router-root.pw; cat /etc/br-lockd/token; echo; } |
		python3 - "$KIT/controller/config.base.json" $D/pve-token.json $D/.config.json "$SITE" "$N" "$HN" "$L" "$IDX" "$T" <<'PY'
import base64, hashlib, json, os, sys
base, tok, out, site, n, node, L, idx, T = sys.argv[1:10]
apw, rpw, ltok = (x.strip() for x in sys.stdin.read().split("\n")[:3])
c = json.load(open(base))
salt = os.urandom(16)
c["admin_hash"] = "pbkdf2$" + base64.b64encode(salt).decode() + "$" + base64.b64encode(
    hashlib.pbkdf2_hmac("sha256", apw.encode(), salt, 310000)).decode()
c["proxmox"].update(host=f"{L}.2", node=node, token_secret=json.load(open(tok))["value"])
c["router"].update(host=f"{L}.1", password=rpw)
c["edge"]["host"] = f"{T}.1"
c["lockd"].update(host=f"{L}.2", token=ltok)
c["hostinfo"] = {"host": f"{L}.2", "port": 8091}
c["sso_proxy"], c["gateway_listen"] = f"{L}.2", f"{L}.10"
c["gateway_peer"] = f"10.255.{idx}.1"
c["identity_url"] = f"http://10.255.{idx}.1:8099/identity.json"
c["gateway_base"] = f"/cwwk{n}"
c["public_url"] = f"https://headscale.l8s.dev/cwwk{n}"
c["site"] = site
fd = os.open(out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
os.write(fd, json.dumps(c, indent=2).encode()); os.close(fd)
PY
	unset apw
	ct_push $CTRL $D/.config.json /etc/br-controller/config.json 0600; shred -u $D/.config.json
	pct exec $CTRL -- sh -c 'systemctl daemon-reload; systemctl enable -q --now br-controller'
	sleep 3
	pct exec $CTRL -- systemctl is-active -q br-controller || die "controller did not start (pct exec $CTRL -- journalctl -u br-controller)"

	cat <<EOF

Installed $SITE. Nothing is cabled yet; the install network (vmbr0) still works.
Secrets (root only): $D/  controller-admin.pw  router-root.pw  pve-token.json  $SITE.join
Next:
  1. bash cwwk-install.sh ports      (the install network ends here; plug modems in after)
  2. plug in the modems and the Spitz, a laptop in any free port
  3. bash cwwk-install.sh finish     (from the CWWK console, or ssh root@$L.2 from the laptop)
EOF
}

# ------------------------------------------------------------------ ports
cmd_ports() {
	load
	pct status $EDGE | grep -q running || pct start $EDGE
	say "port layout: every port on vmbr10 (automatic undo in 15 minutes unless 'finish' runs)"
	/usr/local/sbin/br-port-layout unify
	# the host's way out is now the site router
	python3 - <<PY
import re
p = "/etc/network/interfaces"; s = open(p).read()
s = re.sub(r"(iface vmbr1 inet static\n\taddress $L\.2/24\n)(?!\tgateway)", r"\1\tgateway $L.1\n", s)
open(p, "w").write(s)
PY
	ip route replace default via $L.1 dev vmbr1
	sed -i -E "s/^[0-9.]+([[:space:]]+$HN\.[^[:space:]]+[[:space:]]+$HN)\$/$L.2\1/" /etc/hosts
	systemctl start br-port-roles
	echo
	echo "Ports are on the port bridge. Plug in the modems, the Spitz, and a laptop (any free port)."
	echo "The laptop gets a $L.x address in about a minute: https://$L.10 (admin password: $D/controller-admin.pw)."
	echo "Then: bash cwwk-install.sh finish   (within 15 minutes, or the layout undoes itself)"
}

# ------------------------------------------------------------------ finish
cmd_finish() {
	load; . $D/$SITE.join
	say "tunnel"
	pct exec $EDGE -- sh -c 'systemctl reset-failed black-relay@br0 2>/dev/null; systemctl restart black-relay@br0' || true
	ok=0
	for _ in $(seq 1 24); do
		pct exec $EDGE -- ping -c1 -W2 -I br0 10.255.$IDX.1 >/dev/null 2>&1 && { ok=1; break; }
		sleep 5
	done
	[ $ok = 1 ] || { pct exec $EDGE -- /usr/local/sbin/br-uplinks 2>/dev/null | head -20; die "tunnel not up yet: check modems (the layout undoes itself 15 min after 'ports')"; }
	pct exec $EDGE -- /usr/local/sbin/br-uplinks | python3 -c 'import json,sys; [print(" ", u["port"], u["kind"], u["ip"]) for u in json.load(sys.stdin)["uplinks"] if u.get("ip")]'
	/usr/local/sbin/br-port-layout confirm
	say "host internet through the tunnel"
	ping -c1 -W3 1.1.1.1 >/dev/null || die "host has no way out via $L.1"
	say "tailnet"
	if tailscale status >/dev/null 2>&1; then
		echo "already on the tailnet: $(tailscale ip -4)"
	elif [ -n "${TS_AUTHKEY:-}" ]; then
		systemctl enable -q --now tailscaled
		printf '%s' "$TS_AUTHKEY" >$D/.ts; chmod 600 $D/.ts
		tailscale up --login-server https://headscale.l8s.dev --authkey "file:$D/.ts" \
			--hostname "cwwk-node$(printf %02d "$N")" --accept-dns=false --accept-routes || echo "tailnet join failed (key expired? see README)"
		shred -u $D/.ts
		tailscale ip -4 2>/dev/null | sed 's/^/  tailnet address: /'
	else
		echo "no tailnet key in the join file: see README (tailnet)"
	fi
	sed -i 's/^TS_AUTHKEY=.*/TS_AUTHKEY=/' $D/$SITE.join
	say "host SSH: keys only"
	if [ -s /root/.ssh/authorized_keys ]; then
		printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\n' >/etc/ssh/sshd_config.d/10-black-relay.conf
		systemctl reload ssh
		echo "  password login off (your key in /root/.ssh/authorized_keys)"
	else
		echo "  left as is: put your SSH key in /root/.ssh/authorized_keys, then run finish again"
	fi
	cmd_check
	cat <<EOF

Done: $SITE is on the hub and runs like cwwk01.
Still to do (README): br-vault-init (site lock, USB stick), br-controller-oidc and remote access
(hub-publish-site.sh), spitz-setup.sh (Wi-Fi), then the cold-start test.
EOF
}

# ------------------------------------------------------------------ check
cmd_check() {
	load
	say "check $SITE"
	for id in $EDGE $ROUTER $CTRL; do printf '  CT %s %-14s %s\n' $id "$(pct config $id | sed -n 's/^hostname: //p')" "$(pct status $id | cut -d' ' -f2)"; done
	for u in br-hostinfo br-lockd br-port-roles tailscaled; do printf '  host %-14s %s\n' $u "$(systemctl is-active $u)"; done
	printf '  tunnel        %s\n' "$(pct exec $EDGE -- ping -c1 -W2 -I br0 10.255.$IDX.1 >/dev/null 2>&1 && echo up || echo down)"
	printf '  lanes         %s\n' "$(pct exec $EDGE -- sh -c 'systemctl list-units --no-legend "black-relay-lane-*" 2>/dev/null | grep -c running' || echo 0)"
	printf '  controller    %s\n' "$(pct exec $CTRL -- systemctl is-active br-controller)"
	printf '  site lock     %s\n' "$(/usr/local/sbin/br-lockd status 2>/dev/null | python3 -c 'import json,sys; s=json.load(sys.stdin); print(s.get("state"), "vault" if s.get("vault") else "no vault yet (br-vault-init)")' 2>/dev/null || echo '?')"
	pct exec $EDGE -- /usr/local/sbin/br-selftest 2>/dev/null | tail -15 || true
}

case "${1:-}" in
	plan) cmd_plan "${2:-}" ;;
	install) cmd_install "${2:-}" "${3:-}" ;;
	ports) cmd_ports ;;
	finish) cmd_finish ;;
	check) cmd_check ;;
	*) sed -n '2,20p' "$0"; exit 2 ;;
esac
