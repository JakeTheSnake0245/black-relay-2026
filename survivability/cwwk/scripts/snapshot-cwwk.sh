#!/bin/bash
# snapshot-cwwk.sh — copy the CWWK (cwwk01) as-built configuration into ops/cwwk/as-built/cwwk01/,
# with every secret redacted ON THE HOST. Raw secrets never leave the CWWK.
#
#   bash ops/cwwk/scripts/snapshot-cwwk.sh
#
# Re-runnable: replaces as-built/cwwk01/{host,edge,router,controller}/ and keeps README.md.
# Secrets live only in /root/black-relay/ on the host (never copied, never in git).
set -euo pipefail
HOST=${CWWK_HOST:-root@100.64.0.11}
OUT=$(cd "$(dirname "$0")/.." && pwd)/as-built/cwwk01
mkdir -p "$OUT"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

ssh -o ConnectTimeout=10 "$HOST" 'bash -s' >"$TMP/snap.tar" <<'REMOTE'
set -euo pipefail
T=$(mktemp -d /root/.cwwk-snap.XXXXXX); chmod 700 "$T"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T"/{host,edge,router,controller,state}
cp_host() { for f in "$@"; do [ -e "$f" ] || continue; mkdir -p "$T/host$(dirname "$f")"; cp -p "$f" "$T/host$f"; done; }
ct_cat() { # ct path dest-subdir
	pct exec "$1" -- sh -c "[ -f '$2' ] && cat '$2'" >"$T/tmpf" 2>/dev/null || { rm -f "$T/tmpf"; return 0; }
	mkdir -p "$T/$3$(dirname "$2")"; mv "$T/tmpf" "$T/$3$2"
}
ct_glob() { # ct glob dest-subdir
	for f in $(pct exec "$1" -- sh -c "ls -d $2 2>/dev/null" || true); do ct_cat "$1" "$f" "$3"; done
}

# ---- host (Proxmox)
cp_host /etc/network/interfaces /etc/network/interfaces.d/* /etc/pve/lxc/101.conf /etc/pve/lxc/102.conf /etc/pve/lxc/103.conf /etc/pve/lxc/104.conf
cp_host /etc/br-port-roles.root-ok /etc/br-port-layout.json /etc/hosts /etc/chrony/chrony.conf /etc/ssh/sshd_config.d/*.conf
cp_host /etc/systemd/system/br-*.service /etc/systemd/system/br-*.timer /usr/local/sbin/br-* /etc/sysctl.d/*.conf
cp_host /etc/br-lockd/config.json /etc/br-lockd/cert.pem /etc/pve/storage.cfg   # site lock settings (token and key stay on the host)
for d in /etc/systemd/system/*.service.d; do [ -d "$d" ] && cp_host "$d"/*.conf; done
{ echo "# tailscale serve status"; tailscale serve status 2>&1 || true
  echo; echo "# tailscale ip / tags"; tailscale ip -4 2>&1 || true
  tailscale status --self --json 2>/dev/null | python3 -c 'import json,sys;s=json.load(sys.stdin)["Self"];print(s["DNSName"],s.get("Tags"))' || true
  echo; echo "# advertised subnet routes"; tailscale debug prefs 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin).get("AdvertiseRoutes"))' || true
} >"$T/host/tailscale.txt"
{ echo "# pveum role BlackRelayController"; pveum role list --output-format json 2>/dev/null | python3 -c 'import json,sys;[print(r["roleid"],r.get("privs")) for r in json.load(sys.stdin) if r["roleid"].startswith("BlackRelay")]' || true
  echo "# API tokens (ids only; secrets in /root/black-relay/pve-token.json)"; pveum user token list br-controller@pve --output-format json 2>/dev/null | python3 -c 'import json,sys;[print("br-controller@pve!"+t["tokenid"],"privsep="+str(t.get("privsep"))) for t in json.load(sys.stdin)]' || true
  echo "# ACL"; pveum acl list --output-format json 2>/dev/null | python3 -c 'import json,sys;[print(a["path"],a["ugid"],a["roleid"]) for a in json.load(sys.stdin) if "br-controller" in a["ugid"]]' || true
} >"$T/host/pve-access.txt"
pct list >"$T/host/pct-list.txt"

# ---- edge CT 101 (br-edge)
ct_glob 101 "/etc/black-relay/*.conf /etc/black-relay/black-relay.env /etc/black-relay/dash.json" edge
ct_cat 101 /etc/nftables.conf edge
ct_glob 101 "/etc/systemd/network/* /etc/systemd/networkd.conf.d/* /etc/sysctl.d/*.conf /usr/local/sbin/*" edge
ct_glob 101 "/etc/systemd/system/br-*.service /etc/systemd/system/*.service.d/*.conf /etc/systemd/system/*@*.service.d/*.conf" edge
ct_glob 101 "/etc/dnsmasq.conf /etc/dnsmasq.d/*" edge
ct_cat 101 /root/.ssh/authorized_keys edge
pct exec 101 -- systemctl list-unit-files --state=enabled --no-legend 2>/dev/null | awk '{print $1}' >"$T/edge/enabled-units.txt" || true

# ---- router CT 102 (OpenWrt)
for c in network firewall dhcp wireless system; do
	pct exec 102 -- uci export "$c" >"$T/router/uci-$c.txt" 2>/dev/null || rm -f "$T/router/uci-$c.txt"
done

# ---- controller CT 103
ct_cat 103 /etc/br-controller/config.json controller
ct_glob 103 "/etc/systemd/system/br-controller*.service" controller
pct exec 103 -- sh -c 'cd /opt/br-controller && sha256sum app.py index.html status.html 2>/dev/null' >"$T/controller/deployed-sha256.txt" || true

# ---- live state (evidence, not config): what was actually running when the snapshot was taken
mkdir -p "$T/state"
{ echo "# pveversion"; pveversion; echo; echo "# pct list"; pct list; echo; echo "# free / df"; free -m; df -h / /var/lib/vz 2>/dev/null
  echo; echo "# host ip -br addr"; ip -br addr; echo; echo "# bridge -d link"; bridge -d link; echo; echo "# bridge vlan"; bridge vlan show
  echo; echo "# failed units (host)"; systemctl --failed --no-legend || true
} >"$T/state/host.txt" 2>&1
{ echo "# packages"; pct exec 101 -- sh -c 'dpkg -l | grep -iE "black-relay|wstunnel|nftables|dnsmasq" || true'
  echo; echo "# ip -br addr"; pct exec 101 -- ip -br addr
  echo; echo "# ip rule"; pct exec 101 -- ip rule
  echo; echo "# main routes"; pct exec 101 -- ip route
  echo; echo "# table 201 (site routes)"; pct exec 101 -- ip route show table 201
  echo; echo "# uplinks"; pct exec 101 -- sh -c 'cat /etc/black-relay/br0.conf | grep -E "^(UPLINKS|WSS_LANES|WSS_PREFIX|HUB|SERVER|PORT|TRANSPORT)" || true'
  echo; echo "# units"; pct exec 101 -- systemctl --failed --no-legend
  echo; echo "# tunnel"; pct exec 101 -- sh -c 'systemctl is-active black-relay@br0; journalctl -u black-relay@br0 -n 12 --no-pager 2>/dev/null | cut -c1-200'
} >"$T/state/edge.txt" 2>&1
{ pct exec 104 -- sh -c 'docker ps --format "{{.Names}}	{{.Image}}	{{.Status}}"' ; } >"$T/state/services.txt" 2>&1 || true

# ---- redact everything in place (on the host)
python3 - "$T" <<'PY'
import json, os, re, sys
root = sys.argv[1]
SECRET_KEY = re.compile(r"pass|secret|token|hash|key|psk", re.I)
# Non-secret file-path fields kept so the config stays rebuildable.
KEEP_PATHS = {("tls_cert",), ("tls_key",), ("proxmox", "cafile"), ("router", "cafile"), ("edge", "key")}
R = "<REDACTED>"
def red_json(o, path=()):
    if isinstance(o, dict):
        out = {}
        for k, v in o.items():
            p = path + (k,)
            if SECRET_KEY.search(k) and not isinstance(v, (dict, list)):
                keep = p in KEEP_PATHS and isinstance(v, str) and re.fullmatch(r"/(etc|root/\.ssh)/[A-Za-z0-9._/-]+", v or "")
                out[k] = v if keep else (R if v not in ("", None) else v)
            else:
                out[k] = red_json(v, p)
        return out
    if isinstance(o, list):
        return [red_json(x, path) for x in o]
    return o
LINE_RULES = [
    (re.compile(r"multithread-[0-9a-f]{32}"), "multithread-" + R),
    # shell / env assignments: KEY=..., WSS_PREFIX=..., *PASS*/*SECRET*/*TOKEN*=...
    (re.compile(r"^(\s*(?:export\s+)?(?:KEY|WSS_PREFIX|BR_WS_PREFIX|[A-Z0-9_]*(?:PASS|SECRET|TOKEN|PSK)[A-Z0-9_]*))=(?!\s*$).*$", re.M), r"\1=" + R),
    # uci: option key/password/... 'value'
    (re.compile(r"^(\s*option\s+(?:key|password|sae_password|psk|auth_secret|priv_key|private_key|preshared_key|secret)\s+).*$", re.M), r"\1'" + R + "'"),
    # ssh public key blobs (not secret, but noise): keep options and comment
    (re.compile(r"(ssh-(?:ed25519|rsa)|ecdsa-sha2-nistp\d+) [A-Za-z0-9+/=]{40,}"), r"\1 <pubkey>"),
    (re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----", re.S), R),
]
for d, _, files in os.walk(root):
    for fn in files:
        p = os.path.join(d, fn)
        try:
            s = open(p, encoding="utf-8").read()
        except (UnicodeDecodeError, OSError):
            os.remove(p); continue        # binaries are not config
        if fn.endswith(".json"):
            try:
                s = json.dumps(red_json(json.loads(s)), indent=2) + "\n"
            except ValueError:
                pass
        for rx, rep in LINE_RULES:
            s = rx.sub(rep, s)
        open(p, "w", encoding="utf-8").write(s)
PY
date -u +%Y-%m-%dT%H:%M:%SZ >"$T/SNAPSHOT_TIME"
tar -C "$T" -cf - .
REMOTE

rm -rf "$OUT"/{host,edge,router,controller,state} "$OUT/SNAPSHOT_TIME"
tar -C "$OUT" -xf "$TMP/snap.tar"
echo "snapshot written to $OUT ($(cat "$OUT/SNAPSHOT_TIME")); $(find "$OUT" -type f | wc -l | tr -d ' ') files"
