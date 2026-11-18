#!/bin/bash
# svc-sync.sh: carry the services developed on sf-dev (Hetzner) to the CWWK sites, and show
# which site is out of date. Runs on your Mac; sf-dev and the sites are reached over the tailnet
# (or the site LAN). Nothing is installed on sf-dev: the exporter is piped over SSH.
#
#   bash svc-sync.sh export [NAME...]         build bundles on sf-dev, pull them to ~/Desktop/cwwk-bundles
#   bash svc-sync.sh push HOST [NAME...]      copy to a site and deploy (HOST = root@100.64.0.11, root@10.48.0.2, ...)
#   bash svc-sync.sh sync HOST [NAME...]      export + push in one go  (the usual "ship it")
#   bash svc-sync.sh status [HOST...]         drift: sf-dev version vs what each site runs
#
# Which services: services.json (next to ../services/). A bundle = project files + docker images
# + a version hash (same code and images = same version). Sites keep their own passwords; no
# secret is ever in a bundle. `push` skips a site that already runs the same version (--force
# redeploys). A site with no internet still works: bundles go in the install kit
# (make-kit.sh) or on a USB stick (br-svc deploy FILE.tar).
#
# Overridable: SF=dev@sf-dev  OUT=~/Desktop/cwwk-bundles  SITES="root@100.64.0.11 root@10.48.0.2"
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
CW=$(cd "$HERE/.." && pwd)
CAT=$CW/services/services.json; EXP=$CW/services/br-svc-export
[ -f "$CAT" ] || CAT=$HERE/../services/services.json
SF=${SF:-$(python3 -c "import json;print(json.load(open('$CAT'))['source'])")}
OUT=${OUT:-$HOME/Desktop/cwwk-bundles}
SITES=${SITES:-root@100.64.0.11}
SSHO=(-o BatchMode=yes -o ConnectTimeout=8)
die() { echo "STOP: $*" >&2; exit 1; }
FORCE=0; ARGS=(); for a in "$@"; do [ "$a" = --force ] && FORCE=1 || ARGS+=("$a"); done
set -- "${ARGS[@]:-}"

# one line per wanted service: NAME<TAB>ssh command for the exporter
plan() { # [names...] -> lines "name\tremote command"
	python3 - "$CAT" "$@" <<'PY'
import json, shlex, sys
cat = json.load(open(sys.argv[1])); want = set(sys.argv[2:])
for s in cat["services"]:
    if want and s["name"] not in want: continue
    cmd = ["python3", "-", s["name"], s["root"], s["workdir"], ",".join(s["compose"])]
    if s.get("profiles"): cmd += ["--profiles", ",".join(s["profiles"])]
    if s.get("card"): cmd += ["--card", json.dumps(s["card"])]
    print(s["name"] + "\t" + " ".join(shlex.quote(c) for c in cmd))
PY
}

cmd_export() {
	ssh "${SSHO[@]}" "$SF" true || die "cannot reach $SF (tailnet up? your SSH grant to sf-dev?)"
	mkdir -p "$OUT"
	plan "$@" | while IFS=$'\t' read -r name rcmd; do
		echo "== $name: packing on $SF (first time builds nothing; images must already be built there)"
		line=$(ssh "${SSHO[@]}" "$SF" "$rcmd" <"$EXP" | tail -1) || die "export of $name failed"
		case "$line" in BUNDLE*) ;; *) die "export of $name failed: $line" ;; esac
		remote=$(awk '{print $2}' <<<"$line"); ver=$(awk '{print $4}' <<<"$line")
		if [ -f "$OUT/$name-$ver.tar" ]; then echo "   already have $name-$ver.tar"; else
			scp -q "$SF:$remote" "$OUT/$name-$ver.tar.part" && mv "$OUT/$name-$ver.tar.part" "$OUT/$name-$ver.tar"
			echo "   pulled $name-$ver.tar ($(du -h "$OUT/$name-$ver.tar" | cut -f1))"
		fi
		ls -t "$OUT/$name"-*.tar 2>/dev/null | tail -n +3 | xargs -I{} rm -f {}
	done
}

latest() { ls -t "$OUT/$1"-*.tar 2>/dev/null | head -1; }          # newest local bundle of a service

cmd_push() {
	HOST=${1:-}; [ -n "$HOST" ] || die "usage: svc-sync.sh push HOST [NAME...]"; shift
	ssh "${SSHO[@]}" "$HOST" 'command -v br-svc >/dev/null' || die "cannot reach $HOST or it has no br-svc"
	names=$(plan "$@" | cut -f1)
	[ -n "$names" ] || die "no such service in services.json"
	have=$(ssh "${SSHO[@]}" "$HOST" 'br-svc status --json' 2>/dev/null || echo '{"services":[]}')
	for name in $names; do
		b=$(latest "$name"); [ -n "$b" ] || die "no bundle for $name: run  svc-sync.sh export $name"
		ver=$(basename "$b" .tar); ver=${ver##*-}
		cur=$(python3 -c "import json,sys;print(next((s['version'] for s in json.loads(sys.argv[1])['services'] if s['name']==sys.argv[2]),''))" "$have" "$name")
		if [ "$cur" = "$ver" ] && [ $FORCE = 0 ]; then echo "== $name $ver already on $HOST (use --force to redeploy)"; continue; fi
		echo "== $name: $HOST ${cur:+$cur -> }$ver"
		ssh "${SSHO[@]}" "$HOST" 'mkdir -p /root/bundles'
		scp -q "$b" "$HOST:/root/bundles/"
		ssh -t "$HOST" "br-svc deploy /root/bundles/$(basename "$b") && ls -t /root/bundles/$name-*.tar | tail -n +3 | xargs -r rm -f"
	done
}

cmd_status() {
	hosts=("$@"); [ ${#hosts[@]} -gt 0 ] && [ -n "${hosts[0]}" ] || hosts=($SITES)
	echo "source $SF"
	plan | while IFS=$'\t' read -r name rcmd; do
		v=$(ssh "${SSHO[@]}" "$SF" "$rcmd --version-only" <"$EXP" 2>/dev/null | tail -1 || true)
		[[ "$v" =~ ^[0-9a-f]{12}$ ]] || v="?"
		printf '\n%-14s sf-dev %s\n' "$name" "$v"
		for h in "${hosts[@]}"; do
			j=$(ssh "${SSHO[@]}" "$h" 'br-svc status --json' 2>/dev/null || echo UNREACHABLE)
			python3 - "$j" "$name" "$v" "$h" <<'PY'
import json, sys
j, name, want, host = sys.argv[1:5]
if j == "UNREACHABLE": print("  %-26s unreachable" % host); sys.exit()
try: d = json.loads(j)
except ValueError: print("  %-26s no answer (br-svc missing?)" % host); sys.exit()
s = next((x for x in d["services"] if x["name"] == name), None)
if not s: print("  %-26s NOT DEPLOYED" % host)
else:
    ok = s["running"] == s["containers"] and s["unhealthy"] == 0
    tag = "OK" if s["version"] == want and ok else ("OUTDATED" if s["version"] != want else "UNHEALTHY")
    print("  %-26s %-9s %s  (%d/%d running)" % (host, tag, s["version"], s["running"], s["containers"]))
PY
		done
	done
}

case "${1:-}" in
	export) shift; cmd_export "$@" ;;
	push) shift; cmd_push "$@" ;;
	sync) shift; h=${1:-}; [ -n "$h" ] || die "usage: svc-sync.sh sync HOST [NAME...]"; shift; cmd_export "$@"; cmd_push "$h" "$@" ;;
	status) shift; cmd_status "$@" ;;
	*) sed -n '2,20p' "$0"; exit 2 ;;
esac
