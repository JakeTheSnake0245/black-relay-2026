#!/usr/bin/env python3
"""opn-show.py: read-only look at the cwwk02 OPNsense before/after Phase 2. GET/search requests only.
Uses ~/Desktop/opnsense-api.txt (key=... / secret=...). Endpoints that this OPNsense version does not have just print their HTTP code."""
import base64, json, os, ssl, sys, urllib.error, urllib.parse, urllib.request
HOST = os.environ.get("OPN", "172.22.100.5")
kv = dict(l.strip().split("=", 1) for l in open(os.path.expanduser("~/Desktop/opnsense-api.txt")) if "=" in l)
auth = "Basic " + base64.b64encode(f"{kv['key']}:{kv['secret']}".encode()).decode()
op = urllib.request.build_opener(urllib.request.HTTPSHandler(context=ssl._create_unverified_context()))
def api(path, data=None):
    body = urllib.parse.urlencode(data).encode() if data is not None else None
    try: return json.loads(op.open(urllib.request.Request(f"https://{HOST}{path}", data=body, headers={"Authorization": auth}), timeout=25).read().decode())
    except urllib.error.HTTPError as e: return {"_http": e.code}
    except Exception as e: return {"_err": str(e)[:80]}
Q = {"current": "1", "rowCount": "-1", "searchPhrase": ""}
print("== firmware"); f = api("/api/core/firmware/status"); print("  ", {k: f.get(k) for k in ("product_version", "status", "needs_reboot")} if "_err" not in f else f)
print("== interfaces")
i = api("/api/interfaces/overview/interfacesInfo")
for r in (i.get("rows") or []): print("   %-10s %-14s %-18s %s" % (r.get("identifier"), r.get("description") or r.get("device"), (r.get("addr4") or ""), r.get("status")))
if not i.get("rows"): print("  ", i)
print("== gateways")
g = api("/api/routes/gateway/status")
for r in (g.get("items") or []): print("   %-14s %-16s %-8s loss %s delay %s" % (r.get("name"), r.get("address"), r.get("status_translated"), r.get("loss"), r.get("delay")))
if not g.get("items"): print("  ", g)
print("== outbound NAT")
n = api("/api/firewall/source_nat/search_rule", Q); print("  ", [(r.get("interface"), r.get("source_net"), r.get("target"), r.get("description")) for r in n.get("rows", [])] or n)
print("== unbound / dns")
u = api("/api/unbound/settings/get"); d = u.get("unbound", {}); print("   enabled:", d.get("general", {}).get("enabled"), " forwarding:", d.get("forwarding", {}).get("enabled") if isinstance(d.get("forwarding"), dict) else d.get("forwarding"))
print("== firewall rules (enabled, not automatic)")
fr = api("/api/firewall/filter/search_rule", Q)
for r in fr.get("rows", []):
    if str(r.get("enabled")) == "1" and not r.get("is_automatic", False):
        print("   %-8s %-5s %-6s %s -> %s  gw=%s  %s" % (r.get("interface") or r.get("%interface"), r.get("action"), r.get("protocol"), r.get("source_net"), r.get("destination_net"), r.get("gateway") or "-", (r.get("description") or "")[:40]))
