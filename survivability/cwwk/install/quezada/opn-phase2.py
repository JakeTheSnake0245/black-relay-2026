#!/usr/bin/env python3
"""opn-phase2.py: Phase 2 for the cwwk02 OPNsense, done through its API (no console, no GUI clicks).

    python3 opn-phase2.py status                 read-only: what is configured, what is missing
    QUEZADA_START=yes python3 opn-phase2.py apply [NET ...]   configure everything missing; NET = sources sent through the edge
                                                 (default: 172.22.100.0/24 172.22.41.0/24; first run: pass ONE host as a canary)
    QUEZADA_START=yes python3 opn-phase2.py sources NET ...   change which sources use the edge (canary -> whole LAN)
    QUEZADA_START=yes python3 opn-phase2.py off | on          disable / enable the two policy rules (the rollback switch)

Prerequisites (Proxmox host, once): `qm set 100 -net3 virtio,bridge=vmbr2` (hot-adds vtnet3; no VM restart was needed on 26.7).
Phase 1 must be proven (edge up, hub shows the site) and the edge's site_open gate open for 10.47.0.0/29 (cwwk-addon.sh does that).
Uses ~/Desktop/opnsense-api.txt (key=/secret=). Everything is looked up by name, so running it twice changes nothing the second time.
What it creates: interface BR_TRANSIT (vtnet3, 10.47.0.2/29), gateway BR_EDGE (10.47.0.1, not default, monitored), outbound NAT hybrid +
two rules on BR_TRANSIT, static routes 1.1.1.1/32 + 1.0.0.1/32 via BR_EDGE, Unbound forwarders to them, aliases MP_SiteNets + MP_LocalTailnet,
and two FLOATING quick rules on LAN+services: exception (private ranges + tailnet keep normal routing) then 'internet via BR_EDGE'.
(Floating, because the LAN's 'Default allow' rule sits at sequence 1 and this OPNsense has no savepoint API; undo = `off`.)"""
import base64, json, os, ssl, sys, time, urllib.error, urllib.request

HOST = os.environ.get("OPN", "172.22.100.5"); DEV = os.environ.get("TRANSIT_DEV", "vtnet3")
ADDR, GW, EDGE_NET = "10.47.0.2/29", "10.47.0.1", ("lan", "opt2")
SITE_NETS = ["172.22.100.0/24", "172.22.41.0/24"]
LOCAL = "10.0.0.0/8\n172.16.0.0/12\n192.168.0.0/16\n100.64.0.0/10"
DNS = ["1.1.1.1", "1.0.0.1"]
kv = dict(l.strip().split("=", 1) for l in open(os.path.expanduser("~/Desktop/opnsense-api.txt")) if "=" in l)
AUTH = "Basic " + base64.b64encode(f"{kv['key']}:{kv['secret']}".encode()).decode()
OP = urllib.request.build_opener(urllib.request.HTTPSHandler(context=ssl._create_unverified_context()))
Q = {"current": 1, "rowCount": -1, "searchPhrase": ""}


def call(path, data=None):
    h = {"Authorization": AUTH}; body = None
    if data is not None: body = json.dumps(data).encode(); h["Content-Type"] = "application/json"
    try:
        return json.loads(OP.open(urllib.request.Request(f"https://{HOST}{path}", data=body, headers=h), timeout=60).read().decode())
    except urllib.error.HTTPError as e: return {"_http": e.code}
    except Exception as e: return {"_err": str(e)[:80]}


def ok(r): return r.get("result") == "saved" or "uuid" in r or r.get("status", "").strip().lower() == "ok"
def gate():
    if os.environ.get("QUEZADA_START") != "yes": sys.exit("STOP: this changes the firewall. Jake has not said start (QUEZADA_START=yes only when he does).")
def need(r, what):
    if not ok(r): sys.exit(f"FAILED: {what}: {r}")


def find():
    """Everything Phase 2 owns, looked up by name -> uuid/identifier (None when missing)."""
    f = {}
    a = call("/api/interfaces/assignment/get").get("interface", {}).get("interface", {})
    f["if"] = next((k for k in a if call(f"/api/interfaces/assignment/get_item/{k}").get("interface", {}).get("descr") == "BR_TRANSIT"), None)
    f["gw"] = next((g["uuid"] for g in call("/api/routing/settings/search_gateway").get("rows", []) if g["name"] == "BR_EDGE"), None)
    f["snat_mode"] = next((k for k, v in call("/api/firewall/source_nat/get").get("filter", {}).get("general", {}).get("snat_mode", {}).items() if v.get("selected")), None)
    nat = call("/api/firewall/source_nat/search_rule", Q).get("rows", [])
    f["nat"] = {n: next((r["uuid"] for r in nat if r.get("interface") == "opt3" and r.get("source_net") == n), None) for n in SITE_NETS}
    rts = call("/api/routes/routes/search_route", Q).get("rows", [])
    f["route"] = {d: next((r["uuid"] for r in rts if r["network"] == d + "/32"), None) for d in DNS}
    fw = call("/api/unbound/settings/search_forward", Q).get("rows", [])
    f["fwd"] = {d: next((r["uuid"] for r in fw if r["server"] == d and not r["domain"]), None) for d in DNS}
    al = call("/api/firewall/alias/search_item", Q).get("rows", [])
    f["alias"] = {n: next((r["uuid"] for r in al if r["name"] == n), None) for n in ("MP_SiteNets", "MP_LocalTailnet")}
    rl = call("/api/firewall/filter/search_rule", Q).get("rows", [])
    f["rule"] = {d: next((r for r in rl if (r.get("description") or "").startswith(d)), None) for d in ("Multipath exception", "Multipath: internet-bound")}
    return f


def status():
    f = find(); print("== Phase 2 on", HOST)
    rows = [("interface BR_TRANSIT", f["if"]), ("gateway BR_EDGE", f["gw"]), ("outbound NAT mode hybrid", f["snat_mode"] == "hybrid" or None)]
    rows += [(f"NAT rule {n}", u) for n, u in f["nat"].items()] + [(f"route {d} via BR_EDGE", u) for d, u in f["route"].items()]
    rows += [(f"Unbound forwarder {d}", u) for d, u in f["fwd"].items()] + [(f"alias {n}", u) for n, u in f["alias"].items()]
    rows += [(f"rule: {d}", (r or {}).get("uuid")) for d, r in f["rule"].items()]
    for n, v in rows: print("  %-8s %s" % ("ok" if v else "MISSING", n))
    for g in call("/api/routes/gateway/status").get("items", []):
        if g["name"] == "BR_EDGE": print("  BR_EDGE:", g.get("status_translated"), "loss", g.get("loss"), "delay", g.get("delay"))
    a = f["alias"]["MP_SiteNets"]
    if a:
        c = call(f"/api/firewall/alias/get_item/{a}").get("alias", {}).get("content", {})
        print("  sources through the edge:", sorted(k for k, v in c.items() if v.get("selected")) if isinstance(c, dict) else c)
    for d, r in f["rule"].items():
        if r: print("  rule %-26s enabled=%s gateway=%s" % (d, r.get("enabled"), r.get("gateway") or "-"))
    return f


def apply(nets):
    gate(); f = find(); changed = False
    if not f["if"]:
        dev = call("/api/interfaces/assignment/get_item/opt2").get("interface", {}).get("if", {})
        if DEV not in dev: sys.exit(f"{DEV} is not visible to OPNsense: run on the Proxmox host first: qm set 100 -net3 virtio,bridge=vmbr2")
        r = call("/api/interfaces/assignment/add_item", {"interface": {"if": DEV, "descr": "BR_TRANSIT", "enable": "1", "type4": "staticv4", "ipaddr": ADDR, "blockpriv": "0", "blockbogons": "0"}}); need(r, "interface")
        f["if"] = r["uuid"]; need(call(f"/api/interfaces/assignment/reconfigure/{f['if']}", {}), "interface apply"); print("interface BR_TRANSIT", f["if"], ADDR); changed = True
    if f["if"] != "opt3": sys.exit(f"BR_TRANSIT is {f['if']}, this script's NAT rules assume opt3: adjust before going on")
    if not f["gw"]:
        need(call("/api/routing/settings/add_gateway", {"gateway_item": {"name": "BR_EDGE", "descr": "Black Relay edge (multipath tunnel), CT 110", "interface": f["if"], "ipprotocol": "inet",
             "gateway": GW, "defaultgw": "0", "monitor_disable": "0", "monitor": GW, "priority": "255", "weight": "1"}}), "gateway"); print("gateway BR_EDGE"); changed = True
    if f["snat_mode"] != "hybrid": need(call("/api/firewall/source_nat/set", {"filter": {"general": {"snat_mode": "hybrid"}}}), "NAT mode"); print("outbound NAT -> hybrid"); changed = True
    for n, u in f["nat"].items():
        if not u:
            need(call("/api/firewall/source_nat/add_rule", {"rule": {"enabled": "1", "sequence": "10", "interface": "opt3", "ipprotocol": "inet", "protocol": "any", "source_net": n,
                 "destination_net": "any", "target": "", "description": f"Multipath: {n} via BR_TRANSIT"}}), "NAT rule"); print("NAT rule", n); changed = True
    for d, u in f["route"].items():
        if not u: need(call("/api/routes/routes/add_route", {"route": {"network": d + "/32", "gateway": "BR_EDGE", "descr": "Multipath: DNS via the edge", "disabled": "0"}}), "route"); print("route", d); changed = True
    for d, u in f["fwd"].items():
        if not u: need(call("/api/unbound/settings/add_forward", {"dot": {"enabled": "1", "type": "forward", "domain": "", "server": d, "port": "53", "forward_first": "0", "description": "Multipath: DNS via BR_EDGE"}}), "forwarder"); print("Unbound forwarder", d); changed = True
    for name, content, d in (("MP_SiteNets", "\n".join(nets), "Multipath: sources sent through the edge"), ("MP_LocalTailnet", LOCAL, "Multipath: destinations that keep normal routing (private ranges + tailnet)")):
        if not f["alias"][name]: need(call("/api/firewall/alias/add_item", {"alias": {"enabled": "1", "name": name, "type": "network", "content": content, "description": d, "proto": "", "counters": "0"}}), "alias " + name); print("alias", name); changed = True
    common = {"enabled": "1", "action": "pass", "quick": "1", "interface": ",".join(EDGE_NET), "direction": "in", "ipprotocol": "inet", "protocol": "any", "source_net": "MP_SiteNets"}
    if not f["rule"]["Multipath exception"]:
        need(call("/api/firewall/filter/add_rule", {"rule": dict(common, sequence="5", destination_net="MP_LocalTailnet", description="Multipath exception: private ranges + tailnet keep normal routing")}), "exception rule"); print("rule: exception"); changed = True
    if not f["rule"]["Multipath: internet-bound"]:
        need(call("/api/firewall/filter/add_rule", {"rule": dict(common, sequence="6", destination_net="any", gateway="BR_EDGE", description="Multipath: internet-bound traffic via the edge (BR_EDGE)")}), "cutover rule"); print("rule: via the edge"); changed = True
    if changed:
        for p in ("/api/routing/settings/reconfigure", "/api/routes/routes/reconfigure", "/api/firewall/source_nat/apply", "/api/unbound/service/reconfigure", "/api/firewall/alias/reconfigure", "/api/firewall/filter/apply"):
            print("  ", p.split("/api/")[1], call(p, {}))
    else: print("nothing to do: Phase 2 is already configured")
    if f["alias"]["MP_SiteNets"]: sources(nets, quiet=True)


def sources(nets, quiet=False):
    gate(); u = find()["alias"]["MP_SiteNets"]
    if not u: sys.exit("alias MP_SiteNets missing: run apply first")
    cur = call(f"/api/firewall/alias/get_item/{u}").get("alias", {}).get("content", {})
    have = sorted(k for k, v in cur.items() if v.get("selected")) if isinstance(cur, dict) else sorted(str(cur).split())
    if have == sorted(nets):
        if not quiet: print("sources already:", have)
        return
    need(call(f"/api/firewall/alias/set_item/{u}", {"alias": {"enabled": "1", "name": "MP_SiteNets", "type": "network", "content": "\n".join(nets), "proto": "", "counters": "0",
         "description": "Multipath: sources sent through the edge"}}), "alias update")
    print("sources through the edge:", have, "->", sorted(nets), call("/api/firewall/alias/reconfigure", {}))


def switch(on):
    gate(); f = find()
    for d, r in f["rule"].items():
        if r: print(("enable " if on else "disable ") + d, call(f"/api/firewall/filter/toggle_rule/{r['uuid']}/{1 if on else 0}", {}))
    print("apply:", call("/api/firewall/filter/apply", {}))


if __name__ == "__main__":
    c = sys.argv[1] if len(sys.argv) > 1 else ""
    if c == "status": status()
    elif c == "apply": apply(sys.argv[2:] or SITE_NETS)
    elif c == "sources" and len(sys.argv) > 2: sources(sys.argv[2:])
    elif c in ("on", "off"): switch(c == "on")
    else: print(__doc__)
