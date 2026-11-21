#!/bin/bash
# make-addon-kit.sh: build the Quezada (cwwk02) add-on kit on the Mac. Read-only toward cwwk01.
#
#   bash ops/cwwk/install/quezada/make-addon-kit.sh            -> ~/Desktop/quezada-kit.tar
#
# The kit is everything the node needs for PHASE 1 (edge only), so the install depends on no downloads
# except Debian packages inside the edge container:
#   cwwk-addon.sh                the on-node installer (survey / plan / apply / status / rollback)
#   edge/                        cwwk01's edge as built (as-built tree), minus its identity files
#   pkgs/                        black-relay-glorytun br7 (the hub's exact binary) + wstunnel
#   templates/                   Debian 13 container template (the node has none), cached on the Mac
# No secrets: the join file (hub token, lane prefix) is made at the hub and copied separately.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
CW=$(cd "$HERE/../.." && pwd)                       # ops/cwwk
MP=$(cd "$CW/../multipath" 2>/dev/null || cd "$CW/../../multipath" && pwd)
DIST=${DIST:-$MP/dist}
AB=$CW/as-built/cwwk01
OUT=${1:-$HOME/Desktop/quezada-kit.tar}
SRC=${CWWK_SRC:-root@100.64.0.11}
CACHE=${KITCACHE:-$HOME/Desktop/cwwk-kit-cache}
DEB=black-relay-glorytun_0.3.4+br7_amd64.deb WST=wstunnel_11.1.0_linux_amd64.tar.gz
TPL=debian-13-standard_13.6-1_amd64.tar.zst
K=$(mktemp -d)/quezada-kit; mkdir -p "$K"/{templates,pkgs,edge}
trap 'rm -rf "$(dirname "$K")"' EXIT

echo "== installer + docs"
cp "$HERE/cwwk-addon.sh" "$HERE/README.md" "$HERE/OPNSENSE.md" "$K/"
chmod +x "$K/cwwk-addon.sh"

echo "== edge tree (as-built from cwwk01, snapshot $(cat "$AB/SNAPSHOT_TIME"))"
( cd "$AB/edge" && find etc usr -type f ! -name 'br0.conf' ! -name '*.bak*' | tar -cf - -T - ) | tar -xf - -C "$K/edge"
cp "$MP/edge/br-uplinks-recheck.timer" "$K/edge/etc/systemd/system/"
# br-dash (the edge's read-only dashboard) is in no package: cwwk01 has it installed by hand (the repo copy is byte-identical to it).
mkdir -p "$K/edge/usr/sbin" "$K/edge/usr/share/black-relay/dash"
cp "$MP/packaging/files/br-dash" "$K/edge/usr/sbin/br-dash"; cp "$MP/packaging/files/br-dash.html" "$K/edge/usr/share/black-relay/dash/index.html"
# the HTTPS-lane block of br0.conf, without the secret prefix (the installer adds the site's own)
sed -n '/^# Multithread/,$p' "$AB/edge/etc/black-relay/br0.conf" | grep -v '^WSS_PREFIX=' >"$K/edge/br0.wss.conf"
grep -q '^TRANSPORT=wss' "$K/edge/br0.wss.conf" || { echo "br0.wss.conf has no TRANSPORT=wss: as-built looks wrong"; exit 1; }
chmod +x "$K"/edge/usr/local/sbin/* "$K"/edge/usr/sbin/*
if grep -rIl 'REDACTED' "$K/edge" >/dev/null; then echo "a REDACTED placeholder is in the edge tree:"; grep -rIl REDACTED "$K/edge"; exit 1; fi

echo "== controller (phase 3)"
mkdir -p "$K/controller"
for f in app.py index.html status.html br-controller-network.conf; do cp "$CW/controller/$f" "$K/controller/"; done
cp "$AB/controller/etc/systemd/system/br-controller.service" "$K/controller/"
python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$K/controller/app.py" || { echo "controller app.py does not parse"; exit 1; }
grep -q "class OpnRouter" "$K/controller/app.py" || { echo "controller app.py has no OPNsense router support"; exit 1; }

echo "== packages"
( cd "$DIST" && grep -F "  $DEB" SHA256SUMS | shasum -a 256 -c - ) || { echo "$DEB does not match $DIST/SHA256SUMS"; exit 1; }
cp "$DIST/$DEB" "$DIST/$WST" "$K/pkgs/"

echo "== Debian template"
mkdir -p "$CACHE"
if [ -s "$CACHE/$TPL" ]; then cp "$CACHE/$TPL" "$K/templates/"; echo "   from the cache ($CACHE)"
elif ssh -o BatchMode=yes -o ConnectTimeout=8 "$SRC" true 2>/dev/null; then
	echo "   from cwwk01 (read-only copy)"
	scp -q "$SRC:/var/lib/vz/template/cache/$TPL" "$K/templates/" && cp "$K/templates/$TPL" "$CACHE/"
else echo "no template: cwwk01 ($SRC) is not reachable and $TPL is not cached in $CACHE"; exit 1; fi
[ -s "$K/templates/$TPL" ] || { echo "template copy is empty"; exit 1; }

( cd "$K" && find . -type f ! -name SHA256SUMS | sort | xargs shasum -a 256 >SHA256SUMS )
COPYFILE_DISABLE=1 tar -cf "$OUT" -C "$(dirname "$K")" quezada-kit
echo "kit: $OUT ($(du -h "$OUT" | cut -f1), $(wc -l <"$K/SHA256SUMS" | tr -d ' ') files)"
