#!/bin/bash
# quezada.sh: drive the Quezada (cwwk02) add-on from the Mac. Read-only commands run freely; the ones that
# change the node (push, apply, rollback) refuse unless QUEZADA_START=yes: Jake authorises the start.
#
#   bash quezada.sh preflight        read-only survey of the node (what is there, what blocks Phase 1)
#   bash quezada.sh plan             what 'apply' would do (read-only)
#   bash quezada.sh kit              build ~/Desktop/quezada-kit.tar
#   QUEZADA_START=yes bash quezada.sh push JOINFILE     copy the kit + join file to the node
#   QUEZADA_START=yes bash quezada.sh apply             Phase 1 on the node
#   bash quezada.sh status           edge + tunnel health (read-only)
#   QUEZADA_START=yes bash quezada.sh rollback          remove what apply added
#
# Node login: NODE=root@172.22.100.2 (default). Key login if the key is installed, else export SSHPASS=...
# for this one command (never written to disk). The hub join file comes from BR2026:
#   ssh jake@100.64.0.5 'sudo TRANSIT_LEN=29 bash hub-add-site.sh 2'   then   scp jake@100.64.0.5:cwwk02.join ~/Desktop/
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
NODE=${NODE:-root@172.22.100.2}
KITF=${KITF:-$HOME/Desktop/quezada-kit.tar}
SSHO=(-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
rsh() { if [ -n "${SSHPASS:-}" ]; then sshpass -e ssh -o PubkeyAuthentication=no "${SSHO[@]}" "$@"; else ssh -o BatchMode=yes "${SSHO[@]}" "$@"; fi; }
rcp() { if [ -n "${SSHPASS:-}" ]; then sshpass -e scp -q -o PubkeyAuthentication=no "${SSHO[@]}" "$@"; else scp -q -o BatchMode=yes "${SSHO[@]}" "$@"; fi; }
gate() { [ "${QUEZADA_START:-}" = yes ] || { echo "STOP: '$1' changes the node. Jake has not said start (set QUEZADA_START=yes only when he does)."; exit 3; }; }
reach() { rsh "$NODE" true 2>/dev/null || { echo "cwwk02 ($NODE) is not reachable: it is offline or the tailnet route is down. Nothing was done."; exit 4; }; }

case "${1:-}" in
	preflight) reach; rsh "$NODE" 'bash -s -- survey' <"$HERE/cwwk-addon.sh" ;;
	plan)      bash "$HERE/cwwk-addon.sh" plan ;;
	kit)       bash "$HERE/make-addon-kit.sh" "$KITF" ;;
	push)      gate push; J=${2:-}; [ -r "$J" ] || { echo "usage: push JOINFILE (cwwk02.join from the hub)"; exit 2; }
	           [ -s "$KITF" ] || bash "$HERE/make-addon-kit.sh" "$KITF"; reach
	           rcp "$KITF" "$NODE:/root/quezada-kit.tar"; rcp "$J" "$NODE:/root/cwwk02.join"
	           rsh "$NODE" 'chmod 600 /root/cwwk02.join; rm -rf /root/quezada-kit && tar -xf /root/quezada-kit.tar -C /root && cd /root/quezada-kit && sha256sum -c --quiet SHA256SUMS && echo "kit unpacked and verified on the node"' ;;
	apply)     gate apply; reach; rsh -t "$NODE" 'cd /root/quezada-kit && bash cwwk-addon.sh apply /root/cwwk02.join' ;;
	status)    reach; rsh "$NODE" 'cd /root/quezada-kit 2>/dev/null || cd /root; bash -s -- status' <"$HERE/cwwk-addon.sh" ;;
	rollback)  gate rollback; reach; rsh -t "$NODE" 'cd /root/quezada-kit && bash cwwk-addon.sh rollback' ;;
	*) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
