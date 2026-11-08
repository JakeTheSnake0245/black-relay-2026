#!/bin/bash
# hub-publish-site.sh: remote access to CWWK site N's controller, like cwwk01's:
#   https://headscale.l8s.dev/cwwkN/  ->  BR2026 Caddy  ->  hub (multithread:8443+N)
#   ->  site N tunnel  ->  controller gateway N's LAN .10:8444  (Pocket ID sign-in)
# Run on BR2026 (sudo) once the site's tunnel is up (cwwk-install.sh finish).
#
#   sudo bash hub-publish-site.sh 2
#
# Pins the controller's own certificate (fetched through the tunnel). Caddy is
# validated before the change and restored if the reload fails. Prints no secrets.
set -euo pipefail
N=${1:-}
[[ "$N" =~ ^[2-9]$ ]] || { echo "usage: sudo bash hub-publish-site.sh <site number 2-9>"; exit 2; }
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
SITE=cwwk$(printf %02d "$N"); L=10.$((40 + 8 * (N - 1))).0
HP=$((8443 + N))
HUB=survivability-black-relay CADDY=survivability-caddy CF=/srv/edge/Caddyfile
PUB=/srv/black-relay/etc/publish.conf
STAMP=$(date +%Y%m%d-%H%M%S)
[ -f "$PUB" ] || PUB=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/etc/black-relay"}}{{.Source}}{{end}}{{end}}' $HUB)/publish.conf
[ -f "$PUB" ] || { echo "can't find the hub's publish.conf"; exit 1; }

docker exec $HUB black-relay-hub list | awk -v s="$SITE" '$1==s && $5=="active" {f=1} END {exit !f}' ||
	{ echo "$SITE's tunnel is not active at the hub yet"; exit 1; }

echo "== the controller's certificate, through the tunnel"
pid=$(docker inspect -f '{{.State.Pid}}' $HUB)
der=$(nsenter -t "$pid" -n timeout 10 openssl s_client -connect "$L.10:8444" -servername br-controller </dev/null 2>/dev/null |
	openssl x509 -outform DER 2>/dev/null | base64 -w0)
[ -n "$der" ] || { echo "no answer from $L.10:8444 through the tunnel"; exit 1; }
echo "$der" | base64 -d | openssl x509 -inform DER -noout -subject -ext subjectAltName 2>/dev/null | tr -s ' \n' ' '; echo

echo "== hub: multithread:$HP -> $L.10:8444"
if grep -qE "^$HP[[:space:]]" "$PUB"; then
	echo "already published"
else
	printf '# %s controller remote access (headscale.l8s.dev/cwwk%s/)\n%s %s.10 8444\n' "$SITE" "$N" "$HP" "$L" >>"$PUB"
fi
docker exec $HUB br-supervise publish

echo "== Caddy: /cwwk$N/"
if grep -q "handle_path /cwwk$N/\*" "$CF"; then
	echo "route already present"
else
	python3 - "$CF" /srv/edge/config/Caddyfile.candidate "$N" "$HP" "$der" <<'PY'
import sys
src, dst, n, hp, der = sys.argv[1:6]
t = open(src).read()
anchor = "\thandle {\n\t\treverse_proxy headscale:8080 {"
if t.count(anchor) != 1:
    sys.exit("Caddyfile anchor not found exactly once; aborting")
route = (f"\t# CWWK site {n} controller (same as /cwwk/): Pocket ID inside the controller,\n"
         f"\t# its own self-signed certificate pinned.\n"
         f"\thandle /cwwk{n} {{\n\t\tredir * /cwwk{n}/ 308\n\t}}\n"
         f"\thandle_path /cwwk{n}/* {{\n"
         f"\t\treverse_proxy https://multithread:{hp} {{\n"
         "\t\t\tflush_interval -1\n"
         "\t\t\ttransport http {\n"
         "\t\t\t\ttls_server_name br-controller\n"
         "\t\t\t\ttls_trust_pool inline {\n"
         f"\t\t\t\t\ttrust_der {der}\n"
         "\t\t\t\t}\n\t\t\t}\n\t\t}\n\t}\n")
open(dst, "w").write(t.replace(anchor, route + anchor))
PY
	docker exec $CADDY caddy validate --config /config/Caddyfile.candidate --adapter caddyfile >/dev/null 2>&1 ||
		{ echo "Caddy rejected the new config; Caddy unchanged"; rm -f /srv/edge/config/Caddyfile.candidate; exit 1; }
	cp -p "$CF" "$CF.bak-$STAMP"
	cat /srv/edge/config/Caddyfile.candidate >"$CF"; rm -f /srv/edge/config/Caddyfile.candidate
	if ! docker exec $CADDY caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1; then
		cat "$CF.bak-$STAMP" >"$CF"
		docker exec $CADDY caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1 || true
		echo "Caddy reload failed; restored"; exit 1
	fi
	echo "route added (backup: $CF.bak-$STAMP; delete it once the page works)"
fi
sleep 2
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://headscale.l8s.dev/cwwk$N/" || true)
c1=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://headscale.l8s.dev/cwwk/" || true)
echo "cwwk$N: HTTP $c   cwwk (site 1): HTTP $c1"
echo
echo "Next: Pocket ID -> new OIDC client \"CWWK $N controller\", callback"
echo "  https://headscale.l8s.dev/cwwk$N/oidc/callback  (PKCE on, groups survivability + headscale-users)"
echo "then on the new CWWK host: br-controller-oidc"
