#!/bin/bash
# Capture everything about the current boot of the CWWK site box (after a
# from-scratch power-up) into coldstart/<time>/ on this Mac. Secrets masked.
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=archive/coldstart-captures/$(date +%Y%m%d-%H%M%S); mkdir -p "$OUT"
H=root@100.64.0.11
mask() { sed -E 's/multithread-[0-9a-f]{32}/multithread-<masked>/g; s/(token|secret|password)([^A-Za-z]{1,4})[A-Za-z0-9+\/=_-]{12,}/\1\2<masked>/Ig'; }
run() { ssh -o BatchMode=yes -o ConnectTimeout=20 $H "$2" 2>&1 | mask >"$OUT/$1"; echo "  $1"; }
echo "capturing to $OUT"
run host-boot.txt 'uptime; systemd-analyze; systemd-analyze blame | head -15; echo; systemctl --failed --no-legend; echo; journalctl -b -p warning --no-pager -o short-monotonic | tail -80'
run host-ports.txt '/usr/local/sbin/br-port-layout status; echo; journalctl -b -t br-port-roles --no-pager -o short-monotonic; for n in nic0 nic1 nic2 nic3; do echo "$n carrier=$(cat /sys/class/net/$n/carrier) stp=$(cat /sys/class/net/vmbr10/brif/$n/state)"; done'
run host-guests.txt 'pct list; for id in 101 102 103; do echo "== $id"; pct config $id | grep -E "^(onboot|startup|net)"; done; journalctl -b -u pve-guests --no-pager -o short-monotonic | tail -20'
run edge-boot.txt 'pct exec 101 -- sh -c "uptime; systemd-analyze 2>/dev/null; systemctl --failed --no-legend; journalctl -b -p warning --no-pager -o short-monotonic | tail -60"'
run edge-tunnel.txt 'pct exec 101 -- sh -c "journalctl -b -u black-relay@br0 -u black-relay-watch@br0 -t br-uplinks -t br-lane-nurse -t br-watchdog --no-pager -o short-monotonic | tail -200; echo; cat /run/black-relay/uplinks.json; echo; grep ^UPLINKS /etc/black-relay/br0.conf; /usr/lib/black-relay/glorytun path dev br0 show"'
run edge-network.txt 'pct exec 101 -- sh -c "ip -4 -br addr; ip -4 route show default; ip rule; networkctl status up0 up1 up2 up3 --no-pager 2>&1 | grep -E \"State|Address|Gateway|Link File\""'
run selftest.json 'pct exec 101 -- /usr/local/sbin/br-selftest'
run router.txt 'pct exec 102 -- sh -c "uptime; logread | tail -120; cat /tmp/dhcp.leases"'
run controller.txt 'pct exec 103 -- sh -c "uptime; systemctl --failed --no-legend; journalctl -b -u br-controller --no-pager -o short-monotonic | tail -40"; pct exec 103 -- sh -c "cd /opt/br-controller && python3 -c \"
import app, json
app.identity_load()
s = app.poll_once(app.Proxmox(app.CONF[\\\"proxmox\\\"]), app.Router(app.CONF[\\\"router\\\"]))
print(json.dumps({k: v for k, v in s[\\\"subsystems\\\"].items()}, indent=1)); print(json.dumps(s[\\\"problems\\\"], indent=1))
\""'
echo -n "  public URL: "; curl -s -m10 -o /dev/null -w "%{http_code}\n" https://headscale.l8s.dev/cwwk/ | tee "$OUT/public-url.txt"
echo "done: $OUT"
