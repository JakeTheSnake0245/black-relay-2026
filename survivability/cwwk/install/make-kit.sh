#!/bin/bash
# make-kit.sh: build the install kit for another CWWK site box, on the Mac.
#
#   bash ops/cwwk/install/make-kit.sh            -> ~/Desktop/cwwk-kit.tar
#
# The kit carries everything the new box needs, so the install doesn't depend on
# downloads beyond Debian/Proxmox packages:
#   - this repo's host tools, controller and edge files (the same versions running on cwwk01)
#   - the Debian 13 container template, copied from cwwk01
#   - the router: cwwk01's OpenWrt + LuCI system, copied WITHOUT its passwords, keys,
#     certificates or leases (the installer gives the new router its own)
#   - the multipath package and wstunnel (multipath/dist)
# No secrets go into the kit. cwwk01 is only read.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
CW=$(cd "$HERE/.." && pwd)                       # the CWWK folder (ops/cwwk, or cwwk/ in the repo)
MP=$(cd "$CW/../multipath" 2>/dev/null || cd "$CW/../../multipath" && pwd)
DIST=${DIST:-$MP/dist}                           # built packages (not in git: multipath/packaging/build.sh)
SRC=${CWWK_SRC:-root@100.64.0.11}
OUT=${1:-$HOME/Desktop/cwwk-kit.tar}
K=$(mktemp -d)/cwwk-kit; mkdir -p "$K"/{templates,pkgs,host,controller,edge}
trap 'rm -rf "$(dirname "$K")"' EXIT
AB=$CW/as-built/cwwk01
CT=$CW/controller
DEB=black-relay-glorytun_0.3.4+br6_amd64.deb WST=wstunnel_11.1.0_linux_amd64.tar.gz
TPL=debian-13-standard_13.6-1_amd64.tar.zst

echo "== sources"
cp "$HERE/cwwk-install.sh" "$HERE/spitz-setup.sh" "$HERE/README.md" "$K/"
for f in br-port-roles br-port-layout br-hostinfo br-lockd br-vault-init br-port-lock br-controller-oidc br-rotate-secrets; do
	cp "$CT/$f" "$K/host/"
done
cp "$CT"/br-port-roles.service "$CT"/br-lockd.service "$CT"/br-port-lock.service "$K/host/"
cp "$AB"/host/etc/systemd/system/br-hostinfo.service "$AB"/host/etc/sysctl.d/90-black-relay.conf "$K/host/"
cp "$CT"/app.py "$CT"/index.html "$CT"/status.html "$CT"/br-controller-network.conf "$K/controller/"
cp "$AB"/controller/etc/systemd/system/br-controller.service "$K/controller/"
# controller config: cwwk01's shape and service cards; every secret and per-site value is reset
python3 - "$AB/controller/etc/br-controller/config.json" "$K/controller/config.base.json" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
c["admin_hash"] = ""
c["tls_key"] = "/etc/br-controller/tls.key"
c["proxmox"].update(token_id="br-controller@pve!ui", token_secret="")
c["router"]["password"] = ""
c["edge"]["key"] = "/root/.ssh/id_edge_ctl"
c["oidc"] = {}
c["lockd"]["token"] = ""
c["switches"] = []
for s in c.get("services", []):
    s.update(url="", health_url="", deployed=False)
json.dump(c, open(sys.argv[2], "w"), indent=2)
PY
grep -q '"<REDACTED>"\|<redacted>' "$K/controller/config.base.json" && { echo "a redacted value is left in config.base.json"; exit 1; }
# edge: the tree running on cwwk01 (as-built), minus the files that carry its identity
( cd "$AB/edge" && find etc usr -type f ! -name br0.conf | tar -cf - -T - ) | tar -xf - -C "$K/edge"
cp "$MP/edge/br-uplinks-recheck.timer" "$K/edge/etc/systemd/system/"
cp "$AB/edge/enabled-units.txt" "$K/edge/"
sed -n '/^# Multithread/,$p' "$AB/edge/etc/black-relay/br0.conf" | grep -v '^WSS_PREFIX=' >"$K/edge/br0.wss.conf"
cp "$DIST/$DEB" "$DIST/$WST" "$K/pkgs/"

echo "== Debian template (from cwwk01)"
scp -q "$SRC:/var/lib/vz/template/cache/$TPL" "$K/templates/"

echo "== router system (from cwwk01, without secrets)"
# OpenWrt rootfs; left out: passwords (shadow), SSH host keys and keys (dropbear),
# HTTPS certificate and key (uhttpd), leases and runtime dirs.
ssh "$SRC" 'pct exec 102 -- sh -c "printf \"%s\\n\" \"./proc/*\" \"./sys/*\" \"./dev/*\" \"./tmp/*\" ./lost+found \
	./etc/shadow ./etc/shadow- ./etc/dropbear ./etc/uhttpd.crt ./etc/uhttpd.key ./etc/luci-uploads ./root/.ash_history \
	>/tmp/.kitx; tar -C / -X /tmp/.kitx -cf - .; rc=\$?; rm -f /tmp/.kitx; exit \$rc"' | xz -T0 -6 >"$K/templates/br-router-rootfs.tar.xz"
xz -dc "$K/templates/br-router-rootfs.tar.xz" | tar -tf - >"$K/templates/.router-list"
if grep -qE '^\./etc/(shadow|dropbear/|uhttpd\.(crt|key))' "$K/templates/.router-list"; then
	echo "router export still holds secrets; stopping"; exit 1
fi
grep -q '^\./etc/config/firewall$' "$K/templates/.router-list" || { echo "router export looks incomplete"; exit 1; }
rm "$K/templates/.router-list"

( cd "$K" && find . -type f ! -name SHA256SUMS | sort | xargs shasum -a 256 >SHA256SUMS )
chmod +x "$K"/*.sh "$K"/host/br-* "$K"/edge/usr/local/sbin/*
COPYFILE_DISABLE=1 tar -cf "$OUT" -C "$(dirname "$K")" cwwk-kit
echo "kit: $OUT ($(du -h "$OUT" | cut -f1))"
