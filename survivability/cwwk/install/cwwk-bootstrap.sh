#!/bin/bash
# cwwk-bootstrap.sh: the whole site install in one guided, resumable run, ending in a
# proof (br-verify). Run as root on the new CWWK, from the unpacked kit.
#
#   bash cwwk-bootstrap.sh [N] [JOINFILE]   do everything from where this box is now (N is remembered)
#   bash cwwk-bootstrap.sh --verify         just run the proof again
#   bash cwwk-bootstrap.sh --status         one screen: stages done, what is up (same as: br-status)
#
# Stages: 1 preflight   2 install (containers, keys, host tools)   3 ports (the network moves;
# run from the CONSOLE)   4 modems in   5 finish (tunnel, tailnet, SSH hardening)   6 services
# (the sf-dev bundles in the kit)   7 proof.
# It remembers what is done (/root/black-relay/bootstrap.state). If the network move drops your
# SSH session, log in at the console (or from a laptop on the site LAN: ssh root@10.(40+8(N-1)).0.2)
# and run the same command again; it carries on at the right stage.
#
# A box that already runs other things is added to, not rebuilt: the installer looks first (survey),
# only uses free ports, IDs 101-104 and the vmbr1/2/3/10 names, and stops before changing anything if
# one is taken. Then the port step needs no console (nothing existing drops) and works over SSH.
#
# Things only a person can do stay as clear instructions at the end (USB stick for the site
# lock, Spitz, Pocket ID client). The proof lists each as a WARN until it is done.
set -uo pipefail
KIT=$(cd "$(dirname "$0")" && pwd)
D=/root/black-relay; STATE=$D/bootstrap.state
mkdir -p $D; chmod 700 $D; touch $STATE; chmod 600 $STATE
say()   { printf '\n\033[1m== %s\033[0m\n' "$*"; }
die()   { printf '\nSTOP: %s\n' "$*" >&2; exit 1; }
done_() { grep -qx "$1" $STATE; }
mark()  { done_ "$1" || echo "$1" >>$STATE; }
ask()   { local a; read -r -p "$1 [y/N] " a; [[ "$a" =~ ^[yY] ]]; }
INST()  { bash "$KIT/cwwk-install.sh" "$@"; }

case "${1:-}" in
	--verify) exec /usr/local/sbin/br-verify "${@:2}" ;;
	--status) printf 'stages done: %s\n' "$(tr '\n' ' ' <$STATE)"; [ -x /usr/local/sbin/br-verify ] && exec /usr/local/sbin/br-verify --summary; exit 0 ;;
	-h|--help) sed -n '2,17p' "$0"; exit 0 ;;
esac
[ -n "${1:-}" ] || { [ -r $D/install.env ] && N=$(sed -n 's/^N=//p' $D/install.env); }
[ -n "${1:-}" ] && N=$1
[ -n "${N:-}" ] || { sed -n '2,17p' "$0"; exit 0; }
set -- "$N" "${2:-}"
N=$1; JOIN=${2:-/root/cwwk$(printf %02d "$N").join}
[[ "$N" =~ ^[2-9]$ ]] || die "site number must be 2-9"
SITE=cwwk$(printf %02d "$N"); O=$((8 * (N - 1))); L=10.$((40 + O)).0
CONSOLE=1; [ -n "${SSH_CONNECTION:-}" ] && CONSOLE=0

# ---------------------------------------------------------------- 1 preflight
if ! done_ preflight; then
	say "1/7 preflight"
	[ "$(id -u)" = 0 ] || die "run as root"
	command -v pct >/dev/null || die "this is not a Proxmox host"
	pveversion | grep -q '^pve-manager/9\.' || die "Proxmox VE 9 needed ($(pveversion | cut -d/ -f2))"
	( cd "$KIT" && sha256sum -c --quiet SHA256SUMS ) || die "kit damaged (SHA256SUMS): rebuild it with make-kit.sh"
	[ -r "$JOIN" ] || die "join file $JOIN missing (BR2026: sudo bash hub-add-site.sh $N)"
	grep -q "^SITE=$SITE\$" "$JOIN" || die "$JOIN is not for $SITE"
	grep -q '^JOIN_TOKEN=.\+' "$JOIN" || die "$JOIN has no tunnel token"
	ip -4 route show default | grep -q . || die "no internet route: connect the install network first"
	getent hosts deb.debian.org >/dev/null || die "DNS does not work"
	[ "$(df --output=avail -BG /var/lib/vz | tail -1 | tr -dc 0-9)" -ge 25 ] || die "need 25 GB free on local storage"
	echo "  Proxmox 9, kit intact, join file for $SITE, internet ok"
	if [ -r $D/install.env ]; then echo "  (an install from this kit already started here: not looked at again)"
	else
		SV=$(INST survey "$N" 2>&1); rc=$?; echo "$SV" | sed 's/^/  /'
		[ $rc = 0 ] || die "nothing was changed. The PROBLEM lines above say what is in the way (README: 'A box that already runs things')"
		grep -q 'mode: *ADD' <<<"$SV" || [ -s /root/.ssh/authorized_keys ] || die "no SSH key in /root/.ssh/authorized_keys: host SSH passwords get turned off at the end"
	fi
	mark preflight
fi

# ---------------------------------------------------------------- 2 install
if ! done_ install; then
	say "2/7 install (about 5 minutes; nothing is cabled yet)"
	if pct status 101 >/dev/null 2>&1; then
		[ -r $D/install.env ] || die "containers 101-103 exist but this kit did not make them: not a fresh box"
		echo "  already installed: skipping"
	else
		INST install "$N" "$JOIN" || die "install failed; fix the message above and run this again (the install refuses a half-built box: see the README, 'Check or redo')"
	fi
	mark install
fi

ADOPTED=$(sed -n 's/^ADOPT=//p' $D/install.env 2>/dev/null); PORTSEL=$(sed -n 's/^PORTS="\(.*\)"$/\1/p' $D/install.env 2>/dev/null)
PORTHINT="any ports"; [ "$ADOPTED" = 1 ] && PORTHINT="any of these ports: $PORTSEL"

# ---------------------------------------------------------------- 3 ports
if ! done_ ports && [ "$ADOPTED" = 1 ]; then
	say "3/7 ports: the free ports join Black Relay (the rest of this box stays as it is)"
	cat <<TXT
  Ports given to the site: $PORTSEL. Nothing else changes: the box's other bridges, ports and guests, its own
  network and its route stay as they are, so this works over SSH too. It undoes itself after 15 minutes unless stage 5 runs.
TXT
	ask "  Add those ports now?" || { echo "  Nothing changed. Run this again when ready."; exit 0; }
	INST ports || die "ports step failed"
	mark ports
elif ! done_ ports; then
	say "3/7 ports: the network moves"
	cat <<TXT
  Every port joins the port bridge (any cable, any port) and the install network ends.
  Your SSH session will drop. After this, work from the CONSOLE or from a laptop on the
  site LAN ($L.x, then ssh root@$L.2). It undoes itself after 15 minutes unless stage 5 runs.
TXT
	if [ $CONSOLE = 0 ]; then
		cat <<TXT

  You are on SSH. Stop here, go to the CWWK console (keyboard + screen) and run:
      cd $KIT && bash cwwk-bootstrap.sh $N
TXT
		exit 0
	fi
	ask "  Ready to move the ports?" || { echo "  Nothing changed. Run this again when ready."; exit 0; }
	INST ports || die "ports step failed"
	mark ports
fi

# ---------------------------------------------------------------- 4 modems
if ! done_ modems; then
	say "4/7 cables"
	cat <<TXT
  Plug in now: the modems (Starlink / ISP / the Spitz) in $PORTHINT, and a laptop in a free
  one of them (it gets a $L.x address after about a minute; https://$L.10 is the controller).
  The port layout undoes itself 15 minutes after stage 3, so do this now.
TXT
	ask "  Modems are plugged in?" || { echo "  Run this again when they are."; exit 0; }
	mark modems
fi

# ---------------------------------------------------------------- 5 finish
if ! done_ finish; then
	say "5/7 finish: tunnel, tailnet, SSH hardening"
	if BR_BOOTSTRAP=1 INST finish; then mark finish
	else
		echo
		echo "  finish stopped: usually a modem with no internet yet. Fix it, then run this again."
		echo "  If 15 minutes passed since stage 3 the ports undid themselves: delete the line 'ports'"
		echo "  from $STATE and run this again."
		exit 1
	fi
fi

# ---------------------------------------------------------------- 6 services
if ! done_ services; then
	say "6/7 services (the Sensor Fusion containers from sf-dev)"
	/usr/local/sbin/br-svc init >/dev/null 2>&1 || /usr/local/sbin/br-svc init || echo "  services host not ready; the proof will say so"
	if ls "$KIT"/bundles/*.tar >/dev/null 2>&1; then
		okall=1
		for b in "$KIT"/bundles/*.tar; do
			/usr/local/sbin/br-svc deploy "$b" || { okall=0; echo "  $(basename "$b") did not deploy: fix, then run this again"; }
		done
		[ $okall = 1 ] && mark services
	else
		echo "  no bundles in the kit. Later, from your Mac:  bash svc-sync.sh sync root@$L.2   (or root@<tailnet address>)"
		mark services
	fi
fi

# ---------------------------------------------------------------- 7 proof
say "7/7 proof"
/usr/local/sbin/br-verify; rc=$?
echo
if [ $rc != 0 ]; then
	echo "NOT READY: fix the FAIL lines, then run:  bash cwwk-bootstrap.sh --verify"
	exit 1
fi
if ! done_ services; then
	echo "NOT READY: a service bundle did not deploy (see stage 6 above). Fix it, then run:  bash cwwk-bootstrap.sh"
	exit 1
fi
cat <<TXT
The box works. What is left needs a person (each shows as a WARN above until done):
  - site lock:     USB stick in, then   br-vault-init      (write the passphrase down)
  - Wi-Fi:         laptop on the Spitz:  scp -O spitz-setup.sh root@192.168.9.1:/tmp/ && ssh -t root@192.168.9.1 sh /tmp/spitz-setup.sh
  - remote access: BR2026: sudo bash hub-publish-site.sh $N ; Pocket ID client "CWWK $N controller"
                   (callback https://headscale.l8s.dev/cwwk$N/oidc/callback), then here:  br-controller-oidc
  - services:      logins for each service: br-svc creds <name>; update later from the Mac: bash svc-sync.sh sync root@$L.2
  - port lock:     controller > Setup > Lock the ports
  - join file:     shred -u $JOIN
Then prove it:  br-verify --strict   (all of the above done = READY, no notes)
TXT
exit 0
