#!/bin/bash
# new-site.sh: from your Mac, stand up CWWK site N in one command.
#
#   bash new-site.sh                         asks for the site number and the new box's address
#   bash new-site.sh 2 192.168.1.50          or give them (Proxmox VE 9 on the new box; your SSH
#                                            key is copied for you on the first run)
#
# It does, in order:  checks -> BR2026 registers the site (asks for your sudo password once)
# -> pack the services from sf-dev -> build the kit from cwwk01 -> copy kit + join file to the new box
# -> start the bootstrap there.
# A box that already runs other things (guests, bridges) is added to, never rebuilt: only guest IDs
# 101-104, the vmbr1/2/3/10 names and free ports are used; if one is taken it stops before changing anything.
# On a fresh box the bootstrap stops at the point only a person can do (network move from the console);
# the message says exactly what to type. Nothing here prints or stores a secret on the Mac
# beyond a temporary join file, which is deleted at the end.
#
# Overridable:  HUB=jake@100.64.0.5   CWWK_SRC=root@100.64.0.11   KIT=~/Desktop/cwwk-kit.tar
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
N=${1:-}; HOST=${2:-}
if [ -z "$N" ]; then   # no arguments: ask
	echo "New CWWK site. Needs: the new box running Proxmox VE 9 on a network with internet."
	read -r -p "Site number (2-9; cwwk01 is 1): " N
	read -r -p "The new box's address (shown on its screen, e.g. 192.168.1.50): " HOST
fi
[[ "$N" =~ ^[2-9]$ && -n "$HOST" ]] || { sed -n '2,15p' "$0"; exit 2; }
HOST=${HOST#root@}
HUB=${HUB:-jake@100.64.0.5}; KIT=${KIT:-$HOME/Desktop/cwwk-kit.tar}
SITE=cwwk$(printf %02d "$N")
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
SSHO=(-o BatchMode=yes -o ConnectTimeout=8)
step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
die()  { printf 'STOP: %s\n' "$*" >&2; exit 1; }

step "1/6 checks"
ssh "${SSHO[@]}" "root@$HOST" true 2>/dev/null || { echo "  no key login yet: setting it up (type the box's root password once)"; ssh-copy-id -o ConnectTimeout=8 "root@$HOST" || die "could not copy your SSH key to root@$HOST"; }
ssh "${SSHO[@]}" "root@$HOST" 'pveversion | grep -q "^pve-manager/9\." && echo "  new box: Proxmox 9 ok ($(hostname))"' ||
	die "cannot log in to root@$HOST with your SSH key, or it is not Proxmox VE 9 (ssh-copy-id root@$HOST)"
INV=$(ssh "${SSHO[@]}" "root@$HOST" 'if [ -r /root/black-relay/install.env ]; then echo INSTALLED; fi
n=$(ls /etc/pve/nodes/*/lxc/*.conf /etc/pve/nodes/*/qemu-server/*.conf 2>/dev/null | wc -l); echo "GUESTS $n"
for id in 101 102 103 104; do for f in /etc/pve/nodes/*/lxc/$id.conf /etc/pve/nodes/*/qemu-server/$id.conf; do [ -e "$f" ] && echo "BUSY $id $(sed -n "s/^\(hostname\|name\): //p" "$f" | head -1)"; done; done; true')
grep -q '^INSTALLED' <<<"$INV" && die "Black Relay is already installed on root@$HOST; nothing is changed here. To continue or re-check it, at that box:  cd /root/cwwk-kit && bash cwwk-bootstrap.sh   (or: br-status)"
grep -q '^BUSY' <<<"$INV" && die "root@$HOST already uses guest ID(s) that a site needs: $(grep '^BUSY' <<<"$INV" | awk '{print $2"="$3}' | tr '\n' ' ')(IDs 101-104 are fixed). Nothing was changed; those guests would have to move to other IDs first"
echo "  new box has $(sed -n 's/^GUESTS //p' <<<"$INV") existing guest(s): Black Relay is added next to them, nothing existing is changed or removed"
CACHE=${KITCACHE:-$HOME/Desktop/cwwk-kit-cache}
if ssh "${SSHO[@]}" "${CWWK_SRC:-root@100.64.0.11}" true 2>/dev/null; then SRCMSG="cwwk01 reachable"
elif [ -s "$CACHE/br-router-rootfs.tar.xz" ] && ls "$CACHE"/debian-13-standard_*.tar.zst >/dev/null 2>&1; then
	SRCMSG="cwwk01 not reachable: the kit will use the router image cached $(date -r "$CACHE/br-router-rootfs.tar.xz" '+%F')"
else die "cwwk01 is not reachable and nothing is cached in $CACHE: the first kit has to be built while cwwk01 is up (tailnet, or its LAN)"; fi
ssh "${SSHO[@]}" "$HUB" true || die "BR2026 ($HUB) is not reachable"
echo "  new box and BR2026 reachable; $SRCMSG"

step "2/6 BR2026: register $SITE (sudo password prompt)"
scp -q "$HERE/hub-add-site.sh" "$HUB:"
ssh -t "$HUB" "sudo bash hub-add-site.sh $N"
( umask 077; scp -q "$HUB:$SITE.join" "$TMP/$SITE.join" )
ssh "$HUB" "shred -u $SITE.join hub-add-site.sh 2>/dev/null || rm -f $SITE.join hub-add-site.sh"
grep -q '^JOIN_TOKEN=.\+' "$TMP/$SITE.join" || die "join file came back empty"

step "3/6 services: pack the current sf-dev containers into the kit (SERVICES=0 to skip)"
if [ "${SERVICES:-1}" = 1 ]; then
	bash "$HERE/svc-sync.sh" export || echo "  sf-dev not reachable or export failed: the kit goes without services; push them later with svc-sync.sh"
fi

step "4/6 build the kit (reads cwwk01, changes nothing there)"
bash "$HERE/make-kit.sh" "$KIT"

step "5/6 copy to the new box"
scp -q "$KIT" "$TMP/$SITE.join" "root@$HOST:/root/"
rm -f "$TMP/$SITE.join"
ssh "root@$HOST" "chmod 600 /root/$SITE.join; cd /root && rm -rf cwwk-kit && tar xf $(basename "$KIT")"

step "6/6 bootstrap on the new box (preflight + install, about 5 minutes)"
ssh -t "root@$HOST" "cd /root/cwwk-kit && bash cwwk-bootstrap.sh $N" ||
	echo "  the bootstrap stopped (message above). Fix it, then at the box:  cd /root/cwwk-kit && bash cwwk-bootstrap.sh $N"

cat <<EOF

Next, at the new CWWK console (keyboard + screen):
    cd /root/cwwk-kit && bash cwwk-bootstrap.sh $N
It moves the ports, waits for you to plug in the modems, brings up the tunnel and tailnet,
starts the services from sf-dev, then runs the full proof (br-verify). Anything left for a person is listed at the end.
After it prints READY: on BR2026, 'sudo bash hub-publish-site.sh $N' (remote access; see README step 8).
Delete the kit when done:  rm -P $KIT
EOF
