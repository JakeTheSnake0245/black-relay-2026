#!/usr/bin/env python3
"""Black Relay CWWK controller: one web UI for the whole site box.

Python stdlib only (works offline, nothing to install). Serves HTTPS on the
LAN and aggregates every subsystem into one health model:

  multipath  br-edge (Multithread tunnel): live state from its dashboard API,
             changes through a forced-command SSH key (br-ctl verbs only)
  network    br-router (OpenWrt): ubus JSON-RPC (leases, interfaces, system)
  compute    Proxmox API token (view + power only)
  wifi       Spitz reachability (via br-ctl) + Wi-Fi clients from DHCP
  services   operator-defined cards (Frigate, TAK Server, sensors, ...),
             each with an optional HTTP health check

Every API call needs a login session; changes also need the CSRF token.
Config: /etc/br-controller/config.json (0600).
"""
import base64
import hashlib
import hmac
import html
import http.client
import json
import os
import re
import secrets
import socket
import ssl
import subprocess
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CONF_PATH = os.environ.get("BRC_CONFIG", "/etc/br-controller/config.json")
WEB = os.environ.get("BRC_WEB", "/opt/br-controller/index.html")
POLL = 5  # seconds between backend polls
SESSION_TTL = 12 * 3600

LOCK = threading.Lock()
SESSIONS = {}          # token -> {"exp": t, "csrf": str}
SSO_SECRET = secrets.token_bytes(32)
GW_SESSIONS = {}       # tailnet gateway: token -> {"exp", "csrf", "login", "oidc_role", "sub"}
OIDC_PENDING = {}      # state -> {"exp", "verifier", "nonce", "bind", "login"}
OIDC_META = {"doc": None, "t": 0}
FAILS = {}             # ip -> [count, first_t]  (login rate limit)
STATE = {"t": 0}       # last aggregated snapshot
EVENTS = []            # recent changes / alerts


def load_conf():
    with open(CONF_PATH) as f:
        return json.load(f)


def save_conf(c):
    tmp = CONF_PATH + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(c, f, indent=2)
    os.replace(tmp, CONF_PATH)


CONF = load_conf()


def event(level, text):
    with LOCK:
        EVENTS.insert(0, {"t": time.time(), "level": level, "text": text})
        del EVENTS[60:]


# ---------------------------------------------------------------- auth
def pw_hash(pw, salt=None):
    salt = salt or secrets.token_bytes(16)
    dk = hashlib.pbkdf2_hmac("sha256", pw.encode(), salt, 310000)
    return "pbkdf2$" + base64.b64encode(salt).decode() + "$" + base64.b64encode(dk).decode()


def pw_check(pw, stored):
    try:
        _, s, h = stored.split("$")
        dk = hashlib.pbkdf2_hmac("sha256", pw.encode(), base64.b64decode(s), 310000)
        return hmac.compare_digest(dk, base64.b64decode(h))
    except Exception:
        return False


# ---------------------------------------------------------------- backends
def https_json(host, port, method, path, body=None, headers=None, cafile=None, timeout=6):
    ctx = ssl.create_default_context(cafile=cafile) if cafile else ssl._create_unverified_context()
    if cafile:
        ctx.check_hostname = False  # CA-pinned by file; certs carry no LAN hostname
    c = http.client.HTTPSConnection(host, port, timeout=timeout, context=ctx)
    data = None
    h = dict(headers or {})
    if body is not None:
        if isinstance(body, (dict, list)):
            data = json.dumps(body).encode()
            h.setdefault("Content-Type", "application/json")
        else:
            data = body.encode() if isinstance(body, str) else body
            h.setdefault("Content-Type", "application/x-www-form-urlencoded")
    c.request(method, path, body=data, headers=h)
    r = c.getresponse()
    raw = r.read()
    c.close()
    if r.status >= 400:
        raise RuntimeError(f"{host}:{port}{path} -> HTTP {r.status}")
    return json.loads(raw or b"null")


def http_get_json(host, port, path, timeout=4):
    c = http.client.HTTPConnection(host, port, timeout=timeout)
    c.request("GET", path)
    r = c.getresponse()
    raw = r.read()
    c.close()
    return json.loads(raw)


class Proxmox:
    def __init__(self, c):
        self.host, self.port = c["host"], c.get("port", 8006)
        self.auth = "PVEAPIToken=%s=%s" % (c["token_id"], c["token_secret"])
        self.ca = c.get("cafile")
        self.node = c.get("node", "pve")

    def get(self, path):
        return https_json(self.host, self.port, "GET", "/api2/json" + path,
                          headers={"Authorization": self.auth}, cafile=self.ca)["data"]

    def post(self, path):
        return https_json(self.host, self.port, "POST", "/api2/json" + path, body="",
                          headers={"Authorization": self.auth}, cafile=self.ca)["data"]


class Router:
    """OpenWrt ubus JSON-RPC (rpcd) with a cached session."""

    def __init__(self, c):
        self.host, self.user, self.pw = c["host"], c.get("user", "root"), c["password"]
        self.ca = c.get("cafile")
        self.sid = None

    def _call(self, sid, obj, method, args):
        body = {"jsonrpc": "2.0", "id": 1, "method": "call", "params": [sid, obj, method, args]}
        r = https_json(self.host, 443, "POST", "/ubus", body=body, cafile=self.ca)
        res = r.get("result") or [r.get("error", {}).get("code", -1)]
        return res

    def call(self, obj, method, args=None):
        for _ in range(2):
            if not self.sid:
                res = self._call("00000000000000000000000000000000", "session", "login",
                                 {"username": self.user, "password": self.pw, "timeout": 3600})
                if res[0] != 0:
                    raise RuntimeError("router login failed")
                self.sid = res[1]["ubus_rpc_session"]
            res = self._call(self.sid, obj, method, args or {})
            if res[0] == 6:  # permission denied / expired session
                self.sid = None
                continue
            if res[0] != 0:
                raise RuntimeError(f"ubus {obj}.{method} -> {res[0]}")
            return res[1] if len(res) > 1 else {}
        raise RuntimeError("router session")


def host_info(path, body=None, timeout=4):
    """Read-only host facts (br-hostinfo on the Proxmox host): ports, temps, blink."""
    h = CONF.get("hostinfo", {"host": "10.40.0.2", "port": 8091})
    c = http.client.HTTPConnection(h["host"], h["port"], timeout=timeout)
    if body is None:
        c.request("GET", path)
    else:
        c.request("POST", path, body=json.dumps(body), headers={"Content-Type": "application/json"})
    r = c.getresponse()
    raw = r.read()
    c.close()
    if r.status >= 400:
        raise RuntimeError(f"hostinfo {path} -> HTTP {r.status}")
    return json.loads(raw)


def edge_ctl(*args, timeout=10):
    e = CONF["edge"]
    cmd = ["ssh", "-i", e["key"], "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
           "-o", "StrictHostKeyChecking=yes", f"root@{e['host']}", " ".join(args)]
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    if p.returncode != 0:
        raise RuntimeError((p.stderr or p.stdout).strip()[:200] or "edge command failed")
    return p.stdout.strip()


# ---------------------------------------------------------------- services
# Services arrive in whatever shape their maker uses (a web UI, a TLS-only
# port like TAK's 8089, RTSP cameras, several endpoints, a JSON export).
# Everything is normalised to one card: name, kind (free text), a main link,
# any number of extra links, an address, a health check, notes.
OPEN_SCHEMES = ("http", "https")
LINK_SCHEMES = ("http", "https", "tcp", "udp", "tls", "rtsp", "rtsps", "ssh")
HEALTH_SCHEMES = ("http", "https", "tcp", "tls", "rtsp", "rtsps")


def _pick(d, *keys):
    for k in keys:
        if k in d and d[k] not in (None, ""):
            return d[k]
    return ""


def _url_ok(u, schemes):
    sc = urllib.parse.urlparse(u).scheme
    if sc not in schemes:
        raise ValueError(f"{u[:60]}: use {', '.join(s + '://' for s in schemes)}")
    return u


def service_clean(s):
    if not isinstance(s, dict):
        raise ValueError("each service must be an object")
    name = str(_pick(s, "name", "title", "service", "label")).strip()[:60]
    if not name:
        raise ValueError("every service needs a name")
    sid = re.sub(r"[^a-z0-9-]", "-", str(_pick(s, "id", "slug") or name).lower()).strip("-")[:40] or secrets.token_hex(4)
    url = str(_pick(s, "url", "href", "link", "admin_url", "web", "ui")).strip()[:300]
    health = str(_pick(s, "health_url", "health", "healthcheck", "check")).strip()[:300]
    links = _pick(s, "links", "endpoints", "urls")
    if isinstance(links, dict):
        links = [{"label": k, "url": v} for k, v in links.items()]
    if isinstance(links, str):
        links = [{"label": "", "url": x.strip()} for x in links.splitlines() if x.strip()]
    out_links = []
    for l in (links or [])[:12]:
        if isinstance(l, str):
            lab, _, u = l.rpartition("|") if "|" in l else ("", "", l)
        else:
            lab, u = _pick(l, "label", "name", "title"), _pick(l, "url", "href", "address")
        u = str(u).strip()[:300]
        if u:
            out_links.append({"label": str(lab).strip()[:40], "url": _url_ok(u, LINK_SCHEMES)})
    if url:
        _url_ok(url, LINK_SCHEMES)
    if health:
        _url_ok(health, HEALTH_SCHEMES)
    ports = _pick(s, "address", "host", "ports")
    if isinstance(ports, (list, tuple)):
        ports = ", ".join(str(p) for p in ports)
    return {"id": sid, "name": name, "kind": str(_pick(s, "kind", "type", "category") or "Service")[:40],
            "url": url, "links": out_links, "health_url": health, "address": str(ports)[:120],
            "description": str(_pick(s, "description", "desc", "summary"))[:500],
            "notes": str(_pick(s, "notes", "note"))[:1000],
            "deployed": bool(s.get("deployed", bool(health)))}


def service_parse(text):
    """JSON (one object, a list, or {"services": [...]}), or one service per
    line: name | url | health url | kind."""
    t = text.strip()
    if not t:
        raise ValueError("nothing to import")
    if t[0] in "[{":
        d = json.loads(t)
        if isinstance(d, dict) and isinstance(d.get("services"), (list, dict)):
            d = d["services"]
        if isinstance(d, dict) and not any(k in d for k in ("name", "title", "service")):
            d = [{"name": k, **(v if isinstance(v, dict) else {"url": v})} for k, v in d.items()]
        return d if isinstance(d, list) else [d]
    out = []
    for line in t.splitlines():
        f = [x.strip() for x in line.split("|")]
        if not f[0] or f[0].startswith("#"):
            continue
        out.append({"name": f[0], "url": f[1] if len(f) > 1 else "", "health_url": f[2] if len(f) > 2 else "",
                    "kind": f[3] if len(f) > 3 else ""})
    return out


def http_health(url, timeout=4):
    """Status of a service health URL: (ok, detail)."""
    try:
        u = urllib.parse.urlparse(url)
        port = u.port or {"https": 443, "rtsp": 554, "rtsps": 322}.get(u.scheme, 80)
        if u.scheme == "https":
            c = http.client.HTTPSConnection(u.hostname, port, timeout=timeout,
                                            context=ssl._create_unverified_context())
        elif u.scheme == "http":
            c = http.client.HTTPConnection(u.hostname, port, timeout=timeout)
        elif u.scheme in ("tcp", "rtsp", "rtsps"):
            with socket.create_connection((u.hostname, port), timeout=timeout):
                return True, "port open"
        elif u.scheme == "tls":   # e.g. TAK Server 8089: TLS handshake answers
            ctx = ssl._create_unverified_context()
            with socket.create_connection((u.hostname, port), timeout=timeout) as raw:
                with ctx.wrap_socket(raw, server_hostname=u.hostname):
                    return True, "TLS answers"
        else:
            return None, "no check"
        c.request("GET", u.path or "/")
        r = c.getresponse()
        r.read(256)
        c.close()
        return r.status < 500, f"HTTP {r.status}"
    except Exception as e:
        return False, str(e)[:80]


# ---------------------------------------------------------------- poller
RANK = {"good": 0, "unknown": 1, "warning": 2, "serious": 3, "critical": 4}


def worst(*levels):
    return max(levels, key=lambda l: RANK.get(l, 1)) if levels else "unknown"


def poll_once(pve, router):
    snap = {"t": time.time()}
    subs = {}

    # multipath (edge)
    try:
        mp = http_get_json(CONF["edge"]["host"], CONF["edge"].get("dash_port", 8088), "/api/state")
        mp.pop("history", None)
        snap["multipath"] = mp
        lv = {"good": "good", "warning": "warning", "critical": "critical"}.get(mp.get("overall"), "unknown")
        lanes = [l for l in mp.get("lanes", []) if l.get("addr")]   # empty ports aren't lanes
        up = sum(1 for l in lanes if l.get("health") == "good")
        detail = f"{up}/{len(lanes)} modems healthy · hub {mp.get('ping', {}).get('ms') or '–'} ms · exit {mp.get('egress', {}).get('ip') or '?'}"
        if not mp.get("fail_closed"):
            lv, detail = "critical", "fail-closed guard NOT armed"
        subs["multipath"] = {"level": lv, "detail": detail}
    except Exception as e:
        subs["multipath"] = {"level": "critical", "detail": f"edge unreachable: {e}"[:120]}
    try:
        snap["multipath_conf"] = json.loads(edge_ctl("status"))
    except Exception:
        snap["multipath_conf"] = None

    # network (router)
    try:
        info = router.call("system", "info")
        board = router.call("system", "board")
        dump = router.call("network.interface", "dump").get("interface", [])
        leases = router.call("luci-rpc", "getDHCPLeases").get("dhcp_leases", [])
        ifs = {i["interface"]: {"up": i.get("up"), "addr": [a["address"] + "/" + str(a["mask"]) for a in i.get("ipv4-address", [])],
                                "device": i.get("l3_device") or i.get("device"), "uptime": i.get("uptime")} for i in dump}
        snap["network"] = {"info": info, "board": board, "interfaces": ifs, "leases": leases}
        down = [n for n in ("lan", "wan", "svc") if not ifs.get(n, {}).get("up")]
        subs["network"] = {"level": "critical" if "lan" in down or "wan" in down else ("warning" if down else "good"),
                           "detail": (f"{len(leases)} DHCP clients · uptime {int(info.get('uptime', 0) / 3600)} h"
                                      + (f" · down: {', '.join(down)}" if down else ""))}
    except Exception as e:
        snap["network"] = None
        subs["network"] = {"level": "critical", "detail": f"router API: {e}"[:120]}

    # compute (proxmox)
    try:
        node = pve.node
        ns = pve.get(f"/nodes/{node}/status")
        guests = []
        for kind in ("lxc", "qemu"):
            for g in pve.get(f"/nodes/{node}/{kind}"):
                guests.append({"vmid": g["vmid"], "type": kind, "name": g.get("name"), "status": g.get("status"),
                               "cpu": g.get("cpu", 0), "maxcpu": g.get("cpus") or g.get("maxcpu"),
                               "mem": g.get("mem", 0), "maxmem": g.get("maxmem", 0), "uptime": g.get("uptime", 0),
                               "onboot": None})
        guests.sort(key=lambda g: g["vmid"])
        snap["compute"] = {"node": node, "status": ns, "guests": guests}
        cpu = ns.get("cpu", 0) * 100
        mem = ns["memory"]["used"] / max(1, ns["memory"]["total"]) * 100
        disk = ns["rootfs"]["used"] / max(1, ns["rootfs"]["total"]) * 100
        req = CONF.get("required_guests", [])
        missing = [str(g["vmid"]) for g in guests if g["vmid"] in req and g["status"] != "running"]
        lv = "good"
        if max(cpu, mem, disk) > 90:
            lv = "warning"
        if missing:
            lv = "critical"
        subs["compute"] = {"level": lv, "detail": f"CPU {cpu:.0f}% · RAM {mem:.0f}% · disk {disk:.0f}%"
                           + (f" · stopped: {', '.join(missing)}" if missing else "")}
    except Exception as e:
        snap["compute"] = None
        subs["compute"] = {"level": "critical", "detail": f"Proxmox API: {e}"[:120]}

    # host: physical ports + temperatures
    try:
        snap["ports"] = host_info("/nics")
        snap["temps"] = host_info("/temps")
        cpu_t = snap["temps"].get("cpu")
        if cpu_t is not None and cpu_t >= 85 and "compute" in subs:
            subs["compute"]["level"] = worst(subs["compute"]["level"], "critical" if cpu_t >= 95 else "warning")
            subs["compute"]["detail"] += f" · CPU {cpu_t:.0f} C (hot)"
        elif cpu_t is not None and "compute" in subs:
            subs["compute"]["detail"] += f" · CPU {cpu_t:.0f} C"
    except Exception as e:
        snap["ports"], snap["temps"] = None, None

    # wi-fi (spitz)
    try:
        sp = json.loads(edge_ctl("spitz"))
        snap["wifi"] = sp
        clients = [l for l in (snap.get("network") or {}).get("leases", [])]
        where = sp.get("port") or ""
        subs["wifi"] = {"level": "good" if sp.get("reachable") else "warning",
                        "detail": ("Spitz AP reachable" if sp.get("reachable") else "Spitz AP not answering")
                        + (f" · on {where}" if where else "")}
    except Exception as e:
        snap["wifi"] = None
        subs["wifi"] = {"level": "warning", "detail": f"Spitz status unavailable: {e}"[:120]}

    # services
    svcs = []
    for s in CONF.get("services", []):
        st = dict(s)
        if not s.get("deployed"):
            st["level"], st["detail"] = "unknown", "not deployed yet"
        elif s.get("health_url"):
            ok, d = http_health(s["health_url"])
            st["level"] = "good" if ok else ("unknown" if ok is None else "critical")
            st["detail"] = d
        else:
            st["level"], st["detail"] = "unknown", "no health check"
        svcs.append(st)
    snap["services"] = svcs
    dep = [s for s in svcs if s.get("deployed")]
    subs["services"] = {"level": worst(*[s["level"] for s in dep]) if dep else "good",
                        "detail": f"{len(dep)} deployed · {len(svcs) - len(dep)} planned"}

    with LOCK:
        snap["access"] = identity_view()
    age = (time.time() - IDENT["synced"]) if IDENT.get("synced") else None
    if age is None or age > 6 * 3600:
        snap.setdefault("_access_level", "warning")
    snap["problems"] = problems(snap, subs)
    snap["protected"] = CONF.get("protected_guests", [])
    snap["subsystems"] = subs
    snap["overall"] = worst(*[v["level"] for v in subs.values()])
    return snap


# ---------------------------------------------------------------- identity
# Secret-free snapshot of people / groups / devices / tailnet policy, served by
# the hub through the tunnel. Cached locally so access rules keep working
# offline; refreshed whenever the tunnel is up.
ID_URL = CONF.get("identity_url", "http://10.255.1.1:8099/identity.json")
ID_CACHE = os.path.join(os.path.dirname(CONF_PATH), "identity-cache.json")
IDENT = {"snap": None, "synced": None, "error": None}


def strip_hujson(t):
    """HuJSON (JSON with comments + trailing commas) -> JSON text."""
    out, i, n, ins = [], 0, len(t), False
    while i < n:
        c = t[i]
        if ins:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(t[i + 1]); i += 2; continue
            if c == '"':
                ins = False
            i += 1; continue
        if c == '"':
            ins = True; out.append(c); i += 1; continue
        if t.startswith("//", i):
            while i < n and t[i] != "\n":
                i += 1
            continue
        if t.startswith("/*", i):
            j = t.find("*/", i + 2); i = n if j < 0 else j + 2; continue
        out.append(c); i += 1
    import re as _re
    return _re.sub(r",(\s*[}\]])", r"\1", "".join(out))


def identity_load():
    try:
        with open(ID_CACHE) as f:
            d = json.load(f)
        IDENT.update(snap=d.get("snap"), synced=d.get("synced"))
    except (OSError, ValueError):
        pass


def identity_sync():
    try:
        c = http.client.HTTPConnection(urllib.parse.urlparse(ID_URL).hostname,
                                       urllib.parse.urlparse(ID_URL).port or 80, timeout=10)
        c.request("GET", urllib.parse.urlparse(ID_URL).path)
        r = c.getresponse()
        raw = r.read()
        c.close()
        if r.status != 200:
            raise RuntimeError(f"HTTP {r.status}")
        snap = json.loads(raw)
        json.loads(strip_hujson(snap["policy"]))  # must parse before we trust it
        with LOCK:
            changed = (IDENT["snap"] or {}).get("generated") != snap.get("generated")
            IDENT.update(snap=snap, synced=time.time(), error=None)
        tmp = ID_CACHE + ".tmp"
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump({"snap": snap, "synced": IDENT["synced"]}, f)
        os.replace(tmp, ID_CACHE)
        if changed:
            event("good", f"access rules updated from hub ({len(snap.get('users', []))} people)")
    except Exception as e:
        with LOCK:
            IDENT["error"] = str(e)[:120]


def identity_loop():
    identity_load()
    while True:
        identity_sync()
        time.sleep(60 if IDENT.get("error") else 900)


def role_for_groups(groups):
    g = set(groups or [])
    if g & set(CONF.get("admin_groups", ["survivability"])):
        return "admin"
    if g & set(CONF.get("viewer_groups", ["headscale-users"])):
        return "viewer"
    return None


def principal_for(login):
    """Tailnet login (Pocket ID email) -> {user, role} by LLDAP group, or None."""
    snap = IDENT.get("snap") or {}
    login = (login or "").strip().lower()
    if not login:
        return None
    for u in snap.get("users", []):
        if (u.get("email") or "").lower() == login:
            role = role_for_groups(u.get("groups", []))
            if not role:
                return None
            return {"user": u["id"], "name": u.get("name") or u["id"], "role": role,
                    "groups": sorted(set(u.get("groups", [])))}
    return None


# ---------------------------------------------------------------- Pocket ID (OIDC)
# Remote access: BR2026's Caddy (https://headscale.l8s.dev/cwwk/) reaches
# the gateway listener through the hub and the tunnel, so every connection on it
# comes from the hub's tunnel address. Nothing from the proxy is trusted as
# identity: each person signs in to Pocket ID (authorization code + PKCE) and
# must be in a controller group in both the LLDAP snapshot and Pocket ID's
# groups claim; the role is the lower of the two.
# The ID token comes straight from Pocket ID's token endpoint over verified TLS,
# so its claims are checked (iss, aud, exp, nonce) without a signature check,
# as OIDC Core 3.1.3.7 permits for the code flow.

def oidc_conf():
    o = CONF.get("oidc") or {}
    if not (o.get("issuer") and o.get("client_id") and o.get("client_secret")):
        raise RuntimeError("Pocket ID sign-in is not configured on the controller yet")
    return o


def oidc_https_json(method, url, form=None, bearer=None):
    u = urllib.parse.urlparse(url)
    if u.scheme != "https" or not u.hostname:
        raise RuntimeError("refusing non-HTTPS identity endpoint")
    c = http.client.HTTPSConnection(u.hostname, u.port or 443, timeout=15, context=ssl.create_default_context())
    body = urllib.parse.urlencode(form).encode() if form is not None else None
    h = {"Accept": "application/json", "User-Agent": "br-controller"}
    if body is not None:
        h["Content-Type"] = "application/x-www-form-urlencoded"
    if bearer:
        h["Authorization"] = "Bearer " + bearer
    try:
        c.request(method, (u.path or "/") + ("?" + u.query if u.query else ""), body=body, headers=h)
        r = c.getresponse()
        raw = r.read(1 << 20)
    finally:
        c.close()
    if r.status != 200:
        raise RuntimeError(f"{u.hostname}{u.path}: HTTP {r.status}")
    return json.loads(raw)


def oidc_meta():
    o = oidc_conf()
    with LOCK:
        if OIDC_META["doc"] and time.time() - OIDC_META["t"] < 3600:
            return OIDC_META["doc"]
    doc = oidc_https_json("GET", o["issuer"].rstrip("/") + "/.well-known/openid-configuration")
    if doc.get("issuer") != o["issuer"]:
        raise RuntimeError("Pocket ID issuer mismatch")
    for k in ("authorization_endpoint", "token_endpoint", "userinfo_endpoint"):
        if not str(doc.get(k, "")).startswith("https://"):
            raise RuntimeError(f"Pocket ID {k} missing")
    with LOCK:
        OIDC_META.update(doc=doc, t=time.time())
    return doc


def b64url(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def jwt_claims(tok):
    parts = (tok or "").split(".")
    if len(parts) != 3:
        raise RuntimeError("malformed ID token")
    p = parts[1] + "=" * (-len(parts[1]) % 4)
    return json.loads(base64.urlsafe_b64decode(p))


def gw_base():
    """URL path prefix BR2026's Caddy serves the controller under (stripped before it gets here)."""
    return "/" + CONF.get("gateway_base", "/cwwk").strip("/")


def oidc_redirect_uri():
    return CONF.get("public_url", "https://headscale.l8s.dev/cwwk").rstrip("/") + "/oidc/callback"


def lower_role(a, b):
    return "admin" if a == "admin" and b == "admin" else "viewer"


def identity_view():
    snap = IDENT.get("snap") or {}
    pol = {}
    try:
        pol = json.loads(strip_hujson(snap.get("policy", "{}")))
    except Exception:
        pass
    users = []
    for u in snap.get("users", []):
        pr = principal_for(u.get("email"))
        users.append({"id": u["id"], "name": u.get("name"), "email": u.get("email"),
                      "groups": u.get("groups", []), "cwwk_role": pr["role"] if pr else "none"})
    return {"generated": snap.get("generated"), "synced": IDENT.get("synced"), "error": IDENT.get("error"),
            "users": users, "groups": snap.get("groups", []), "nodes": snap.get("nodes", []),
            "policy": {"groups": pol.get("groups", {}), "hosts": pol.get("hosts", {}),
                       "tagOwners": pol.get("tagOwners", {}), "grants": pol.get("grants", []),
                       "autoApprovers": pol.get("autoApprovers", {})},
            "admin_groups": CONF.get("admin_groups", ["survivability"]),
            "viewer_groups": CONF.get("viewer_groups", ["headscale-users"])}


UPLINK_NIC = {"up0": "nic0", "up1": "nic1", "up2": "nic2", "up3": "nic3"}


def problems(snap, subs):
    """Plain-language problems with numbered fixes, worst first."""
    out = []
    ports = {p["nic"]: p for p in (snap.get("ports") or [])}
    mp = snap.get("multipath") or {}
    lanes = mp.get("lanes") or []
    good_lanes = [l for l in lanes if l.get("health") == "good"]

    def add(level, title, steps):
        out.append({"level": level, "title": title, "steps": steps})

    if subs.get("multipath", {}).get("level") == "critical" and not mp:
        add("critical", "Controller can't reach the multipath box", [
            "Open Compute and check that 101 br-edge is running; press Start if it is stopped.",
            "If it is running, wait one minute; it may be restarting.",
            "Still down: reboot the whole CWWK (hold the power button 5 s, then press it again)."])
    elif mp and (mp.get("ping") or {}).get("ok") is False or (lanes and not good_lanes):
        add("critical", "No internet: the tunnel to the hub is down", [
            "Look at the uplink cards below: at least one uplink needs a green link and an address.",
            "Run the Self-test (Setup page). If every modem answers but no lanes run, the hub or its internet is down: call the hub admin. The site stays safe meanwhile (nothing leaks out unencrypted).",
            "Try Multipath, Restart tunnel.",
            "Still down after 2 minutes: reboot the CWWK."])
    for l in lanes:
        nic = l.get("port") or UPLINK_NIC.get(l.get("if"), "?")
        port = ports.get(nic) or {}
        if l.get("health") == "good" or not port.get("link") or port.get("mode") == "client":
            continue   # healthy, empty port, or a client device: nothing to fix
        name = l.get("label") or nic
        if not l.get("addr"):
            if port.get("wifi"):
                continue   # an access point still coming up
            add("warning", f"{nic}: something is plugged in but it gives no address (yet)", [
                "A modem: power-cycle it (unplug power 10 s). Starlink needs up to 5 minutes after power-on.",
                "A laptop or switch: give it a minute; it joins the site network by itself. Still nothing after 2 minutes: unplug it 5 s and plug back in.",
                "The lane joins automatically when the modem is ready."])
        else:
            add("warning", f"{name}: modem connected, but no internet on it", [
                "This modem's own internet is down. The other modems carry the traffic meanwhile.",
                "Starlink: check obstructions / stow state in the Starlink app (or its quick link on Setup).",
                "Spitz: check signal and data plan (SIM). ISP: check the ISP router's own internet.",
                "Run the Self-test to see whether the modem itself answers."])
    if ports and not any(l.get("addr") for l in lanes) and not any(p.get("link") and p.get("mode") != "client" for p in ports.values()):
        add("critical", "No modem plugged in", [
            "Plug at least one modem (ISP, Starlink, Spitz) into any free port on the CWWK.",
            "Use Setup, Blink port to find the ports."])
    wifi_on = any(p.get("wifi") for p in ports.values()) or (snap.get("wifi") or {}).get("reachable")
    if ports and not wifi_on:
        add("warning", "No Wi-Fi access point found", [
            "Plug the Spitz LAN port into any free port on the CWWK (one cable only).",
            "Check the Spitz is powered on (screen / lights); give it 2 minutes after power-on."])
    if subs.get("network", {}).get("level") == "critical":
        add("critical", "Router not answering: no DHCP / DNS for devices", [
            "Open Compute and start 102 br-router if it is stopped.",
            "Devices that already have an address keep working for a while.",
            "Still down: reboot the CWWK."])
    t = (snap.get("temps") or {}).get("cpu")
    if t is not None and t >= 85:
        add("critical" if t >= 95 else "warning", f"CWWK is hot ({t:.0f} C)", [
            "Move it out of direct sun and give it airflow; it has no fan.",
            "Do not cover it or stack gear on top of it.",
            "Above ~100 C it slows itself down to protect the CPU."])
    if mp and not mp.get("fail_closed"):
        add("critical", "Leak guard NOT armed", [
            "Do not use the network for sensitive traffic until fixed.",
            "Reboot the CWWK; the guard is set up at boot.",
            "If it stays unarmed, call the operator who built the kit."])
    out.sort(key=lambda p: -RANK.get(p["level"], 1))
    return out


def poller():
    pve, router = Proxmox(CONF["proxmox"]), Router(CONF["router"])
    prev = {}
    while True:
        t0 = time.time()
        try:
            snap = poll_once(pve, router)
            for k, v in snap["subsystems"].items():
                if prev.get(k) and prev[k] != v["level"]:
                    event(v["level"] if v["level"] != "unknown" else "warning",
                          f"{k}: {prev[k]} → {v['level']} ({v['detail']})")
                prev[k] = v["level"]
            with LOCK:
                STATE.clear()
                STATE.update(snap)
        except Exception as e:
            event("warning", f"poller: {e}"[:160])
        time.sleep(max(0.5, POLL - (time.time() - t0)))


# ---------------------------------------------------------------- actions
def do_action(body):
    area, action = body.get("area"), body.get("action")
    if area == "multipath":
        v = str(body.get("value", "")).strip()
        allowed = {"set-sched", "set-hold", "set-lanes", "set-caps", "restart-tunnel"}
        if action not in allowed:
            raise ValueError("unknown multipath action")
        if any(ch in v for ch in ";|&$`'\"\\<>()\n"):
            raise ValueError("bad value")
        out = edge_ctl(action, v) if v else edge_ctl(action)
        event("good", f"multipath {action} {v}".strip())
        return out
    if area == "setup":
        if action == "blink":
            nic = str(body.get("nic", ""))
            if nic not in {p["nic"] for p in (STATE.get("ports") or [])}:
                raise ValueError("unknown port")
            host_info("/blink", {"nic": nic})
            return f"{nic} LED is blinking for 15 s"
        if action == "selftest":
            res = json.loads(edge_ctl("selftest", timeout=60))
            res["ports"] = host_info("/nics")
            with LOCK:
                STATE["selftest"] = res
            event("good", "self-test run")
            return res
        raise ValueError("bad setup action")
    if area == "compute":
        vmid, kind = int(body["vmid"]), body.get("type")
        if kind not in ("lxc", "qemu") or action not in ("start", "shutdown", "reboot"):
            raise ValueError("bad compute action")
        if vmid in CONF.get("protected_guests", []) and action != "start":
            raise ValueError(f"{vmid} is protected (it carries the site's network)")
        pve = Proxmox(CONF["proxmox"])
        out = pve.post(f"/nodes/{pve.node}/{kind}/{vmid}/status/{action}")
        event("good", f"{kind} {vmid}: {action}")
        return out
    if area == "services":
        svcs = CONF.setdefault("services", [])
        if action == "save":
            clean = service_clean(body.get("service") or {})
            svcs[:] = [x for x in svcs if x.get("id") != clean["id"]] + [clean]
            save_conf(CONF)
            event("good", f"service saved: {clean['name']}")
            return "saved"
        if action == "import":
            items = service_parse(str(body.get("text", ""))[:200000])
            cleaned = [service_clean(x) for x in items]
            ids = {c["id"] for c in cleaned}
            svcs[:] = [x for x in svcs if x.get("id") not in ids] + cleaned
            save_conf(CONF)
            event("good", f"imported {len(cleaned)} service(s)")
            return f"imported {len(cleaned)} service(s)"
        if action == "delete":
            sid = body.get("id")
            svcs[:] = [x for x in svcs if x.get("id") != sid]
            save_conf(CONF)
            return "deleted"
        raise ValueError("bad services action")
    if area == "settings" and action == "password":
        new = body.get("new", "")
        if not pw_check(body.get("current", ""), CONF["admin_hash"]):
            raise PermissionError("current password is wrong")
        if len(new) < 12:
            raise ValueError("use at least 12 characters")
        CONF["admin_hash"] = pw_hash(new)
        save_conf(CONF)
        with LOCK:
            SESSIONS.clear()
        event("good", "admin password changed")
        return "changed; log in again"
    raise ValueError("unknown action")


# ---------------------------------------------------------------- http
class H(BaseHTTPRequestHandler):
    server_version = "br-controller"
    sys_version = ""

    def log_message(self, *a):
        pass

    def hdr(self, code, ctype, extra=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "SAMEORIGIN")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Strict-Transport-Security", "max-age=31536000")
        self.send_header("Content-Security-Policy",
                         "default-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; "
                         "img-src 'self' data:; frame-src 'self'; frame-ancestors 'self'")
        for k, v in (extra or {}).items():
            self.send_header(k, v)

    def json(self, code, obj, extra=None):
        b = json.dumps(obj).encode()
        self.hdr(code, "application/json", extra)
        self.end_headers()
        self.wfile.write(b)

    def cookie(self, name):
        for part in self.headers.get("Cookie", "").split(";"):
            k, _, v = part.strip().partition("=")
            if k == name:
                return v
        return None

    def gw_peer_ok(self):
        """Gateway listener: only BR2026's Caddy, arriving through the hub's
        tunnel address (replies route back through the tunnel, so LAN hosts
        cannot complete a connection with that source)."""
        return getattr(self.server, "gw", False) and self.client_address[0] == CONF.get("gateway_peer", "10.255.1.1")

    def session(self):
        if getattr(self.server, "gw", False):
            if not self.gw_peer_ok():
                return None, None
            tok = self.cookie("__Secure-brg")
            with LOCK:
                s = GW_SESSIONS.get(tok or "")
                if s and s["exp"] <= time.time():
                    GW_SESSIONS.pop(tok, None)
                    s = None
            pr = principal_for(s["login"]) if s else None
            if not pr:   # removed from the controller groups since sign-in
                return None, None
            return tok, {"csrf": s["csrf"], "role": lower_role(pr["role"], s["oidc_role"]),
                         "user": pr["name"], "via": "Pocket ID"}
        # Legacy tailnet sign-in (Tailscale Serve, plain HTTP); off once the gateway is live.
        if getattr(self.server, "sso", False):
            if self.client_address[0] != CONF.get("sso_proxy", "10.40.0.2"):
                return None, None
            pr = principal_for(self.headers.get("Tailscale-User-Login"))
            if not pr:
                return None, None
            csrf = hmac.new(SSO_SECRET, pr["user"].encode(), hashlib.sha256).hexdigest()[:32]
            return "sso:" + pr["user"], {"csrf": csrf, "role": pr["role"], "user": pr["name"], "via": "tailnet"}
        ck = self.headers.get("Cookie", "")
        for part in ck.split(";"):
            k, _, v = part.strip().partition("=")
            if k == "brc":
                with LOCK:
                    s = SESSIONS.get(v)
                    if s and s["exp"] > time.time():
                        return v, s
                    SESSIONS.pop(v, None)
        return None, None

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n > 65536:
            raise ValueError("body too large")
        return json.loads(self.rfile.read(n) or b"{}")

    def page(self, code, title, msg, retry=True):
        b = ("<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width'>"
             "<title>Black Relay</title><body style='font:15px system-ui;max-width:520px;margin:12vh auto;padding:0 16px'>"
             f"<h2>{html.escape(title)}</h2><p>{html.escape(msg)}</p>"
             + (f"<p><a href='{gw_base()}/oidc/login'>Try again</a> &middot; <a href='{gw_base()}/'>Controller</a></p>" if retry else "")
             ).encode()
        self.hdr(code, "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write(b)

    def oidc_login(self):
        try:
            m = oidc_meta()
            o = oidc_conf()
        except Exception as e:
            self.page(503, "Pocket ID sign-in unavailable", f"{str(e)[:160]}. If the tunnel is down, sign in on the site LAN at https://10.40.0.10.", False)
            return
        state, nonce, verifier, bind = (secrets.token_urlsafe(24), secrets.token_urlsafe(24),
                                        secrets.token_urlsafe(48), secrets.token_urlsafe(24))
        now = time.time()
        with LOCK:
            for k in [k for k, v in OIDC_PENDING.items() if v["exp"] < now]:
                OIDC_PENDING.pop(k, None)
            while len(OIDC_PENDING) >= 1000:   # internet-facing: evict the oldest, never lock out
                OIDC_PENDING.pop(min(OIDC_PENDING, key=lambda k: OIDC_PENDING[k]["exp"]), None)
            OIDC_PENDING[state] = {"exp": now + 600, "verifier": verifier, "nonce": nonce, "bind": bind}
        q = urllib.parse.urlencode({
            "response_type": "code", "client_id": o["client_id"], "redirect_uri": oidc_redirect_uri(),
            "scope": o.get("scope", "openid email profile groups"), "state": state, "nonce": nonce,
            "code_challenge": b64url(hashlib.sha256(verifier.encode()).digest()), "code_challenge_method": "S256"})
        self.send_response(302)
        self.send_header("Location", m["authorization_endpoint"] + "?" + q)
        self.send_header("Set-Cookie", f"brst={bind}; Path={gw_base()}/oidc; Secure; HttpOnly; SameSite=Lax; Max-Age=600")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def oidc_callback(self, query):
        qs = urllib.parse.parse_qs(query)
        if qs.get("error"):
            self.page(403, "Pocket ID refused the sign-in", qs.get("error_description", qs["error"])[0][:200])
            return
        state, code = qs.get("state", [""])[0], qs.get("code", [""])[0]
        with LOCK:
            p = OIDC_PENDING.pop(state, None)
        if not p or p["exp"] < time.time() or not code:
            self.page(400, "Sign-in expired", "Start again from the controller.")
            return
        if not hmac.compare_digest((self.cookie("brst") or "").encode(), p["bind"].encode()):
            self.page(400, "Sign-in must finish in the same browser", "Start again from the controller.")
            return
        try:
            o, m = oidc_conf(), oidc_meta()
            tok = oidc_https_json("POST", m["token_endpoint"], form={
                "grant_type": "authorization_code", "code": code, "redirect_uri": oidc_redirect_uri(),
                "client_id": o["client_id"], "client_secret": o["client_secret"], "code_verifier": p["verifier"]})
            idt = jwt_claims(tok.get("id_token"))
            aud = idt.get("aud")
            aud = aud if isinstance(aud, list) else [aud]
            if idt.get("iss") != o["issuer"] or o["client_id"] not in aud:
                raise RuntimeError("ID token not issued for this controller")
            if float(idt.get("exp", 0)) < time.time() - 60:
                raise RuntimeError("ID token expired")
            if not hmac.compare_digest(str(idt.get("nonce", "")).encode(), p["nonce"].encode()):
                raise RuntimeError("ID token nonce mismatch")
            ui = oidc_https_json("GET", m["userinfo_endpoint"], bearer=tok.get("access_token"))
            if ui.get("sub") != idt.get("sub"):
                raise RuntimeError("userinfo subject mismatch")
        except Exception as e:
            event("warning", f"Pocket ID sign-in failed: {str(e)[:120]}")
            self.page(502, "Pocket ID sign-in failed", str(e)[:200])
            return
        login = str(ui.get("email") or idt.get("email") or "").strip().lower()
        orole = role_for_groups(ui.get("groups") or idt.get("groups") or [])
        pr = principal_for(login)
        if not orole or not pr:
            event("warning", f"Pocket ID sign-in by {login} refused: no controller group")
            self.page(403, "Not allowed", f"{login or 'This account'} has no controller access. Ask a survivability admin.", False)
            return
        stok, csrf = secrets.token_urlsafe(32), secrets.token_urlsafe(24)
        with LOCK:
            for k in [k for k, v in GW_SESSIONS.items() if v["exp"] < time.time()]:
                GW_SESSIONS.pop(k, None)
            GW_SESSIONS[stok] = {"exp": time.time() + SESSION_TTL, "csrf": csrf, "login": login,
                                 "oidc_role": orole, "sub": idt.get("sub")}
        event("good", f"{pr['name']} signed in remotely (Pocket ID, {lower_role(pr['role'], orole)})")
        self.send_response(302)
        self.send_header("Location", gw_base() + "/")
        self.send_header("Set-Cookie", f"__Secure-brg={stok}; Path={gw_base()}/; Secure; HttpOnly; SameSite=Strict; Max-Age={SESSION_TTL}")
        self.send_header("Set-Cookie", f"brst=; Path={gw_base()}/oidc; Secure; HttpOnly; SameSite=Lax; Max-Age=0")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def gw_reject(self):
        """The gateway listener only talks to BR2026's Caddy (via the tunnel)."""
        if getattr(self.server, "gw", False) and not self.gw_peer_ok():
            self.hdr(403, "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write(b"forbidden\n")
            return True
        return False

    # ----- GET
    def do_GET(self):
        if self.gw_reject():
            return
        u = urllib.parse.urlparse(self.path)
        path = u.path
        if getattr(self.server, "gw", False):
            if path == "/oidc/login":
                self.oidc_login()
                return
            if path == "/oidc/callback":
                self.oidc_callback(u.query)
                return
            if path in ("/status", "/status/", "/api/public"):   # site LAN only
                self.json(404, {"error": "not found"})
                return
        if path in ("/", "/index.html"):
            with open(WEB, "rb") as f:
                b = f.read()
            self.hdr(200, "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(b)
            return
        if path in ("/status", "/status/"):
            with open(os.path.join(os.path.dirname(WEB), "status.html"), "rb") as f:
                b = f.read()
            self.hdr(200, "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(b)
            return
        if path == "/api/public":
            with LOCK:
                mp = STATE.get("multipath") or {}
                lanes = mp.get("lanes") or []
                pub = {"t": STATE.get("t"), "overall": STATE.get("overall", "unknown"),
                       "internet": bool((mp.get("ping") or {}).get("ok")) and any(l.get("health") == "good" for l in lanes),
                       "uplinks": [{"name": l.get("label"), "ok": l.get("health") == "good"} for l in lanes],
                       "wifi": (STATE.get("subsystems") or {}).get("wifi", {}).get("level") == "good"}
            self.json(200, pub)
            return
        if path == "/api/session":
            tok, s = self.session()
            gw = getattr(self.server, "gw", False)
            if gw:
                allowed, sso_login = True, None
            else:
                sso_login = self.headers.get("Tailscale-User-Login") if getattr(self.server, "sso", False) else None
                allowed = False
            self.json(200, {"authed": bool(s), "csrf": s["csrf"] if s else None,
                            "role": s.get("role") if s else None, "user": s.get("user") if s else None,
                            "via": s.get("via") if s else None, "sso": getattr(self.server, "sso", False) or gw,
                            "gateway": gw, "tailnet_login": sso_login if gw else None,
                            "login_url": "/oidc/login" if (gw and allowed and not s) else None,
                            "denied_login": sso_login if (sso_login and not s and not allowed) else None})
            return
        tok, s = self.session()
        if not s:
            self.json(401, {"error": "login required"})
            return
        if path == "/api/state":
            with LOCK:
                out = dict(STATE)
                out["events"] = list(EVENTS[:30])
            self.json(200, out)
        elif path == "/api/events":
            self.hdr(200, "text/event-stream")
            self.end_headers()
            try:
                while True:
                    with LOCK:
                        out = dict(STATE)
                        out["events"] = list(EVENTS[:30])
                    self.wfile.write(b"data: " + json.dumps(out).encode() + b"\n\n")
                    self.wfile.flush()
                    time.sleep(POLL)
                    if not self.session()[1]:
                        return
            except (BrokenPipeError, ConnectionResetError):
                return
        elif path.startswith("/mp/"):
            self.proxy_dash(path[3:] or "/")
        else:
            self.json(404, {"error": "not found"})

    def proxy_dash(self, sub):
        """Multithread dashboard (br-edge) under /mp/, so one origin serves all."""
        e = CONF["edge"]
        stream = sub.startswith("/api/events")
        try:
            # live event stream: no read timeout (the dashboard sends every
            # second); everything else: a normal bounded request
            c = http.client.HTTPConnection(e["host"], e.get("dash_port", 8088), timeout=None if stream else 10)
            c.request("GET", sub)
            r = c.getresponse()
            self.hdr(r.status, r.getheader("Content-Type", "application/octet-stream"))
            self.end_headers()
            if stream:
                while True:
                    chunk = r.read1(4096)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    self.wfile.flush()
                    if not self.session()[1]:   # logged out: stop relaying
                        break
            else:
                self.wfile.write(r.read())
            c.close()
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as ex:
            try:
                self.json(502, {"error": f"dashboard: {ex}"})
            except Exception:
                pass

    # ----- POST
    def do_POST(self):
        if self.gw_reject():
            return
        path = urllib.parse.urlparse(self.path).path
        ip = self.client_address[0]
        try:
            if path == "/api/login" and (getattr(self.server, "gw", False) or getattr(self.server, "sso", False)):
                self.json(403, {"error": "password sign-in is LAN-only; use Pocket ID"})
                return
            if path == "/api/login":
                with LOCK:
                    n, t0 = FAILS.get(ip, [0, time.time()])
                    if time.time() - t0 > 900:
                        n, t0 = 0, time.time()
                    if n >= 8:
                        self.json(429, {"error": "too many attempts; wait 15 minutes"})
                        return
                b = self.body()
                if pw_check(b.get("password", ""), CONF["admin_hash"]):
                    tok, csrf = secrets.token_urlsafe(32), secrets.token_urlsafe(24)
                    with LOCK:
                        SESSIONS[tok] = {"exp": time.time() + SESSION_TTL, "csrf": csrf,
                                         "role": "admin", "user": "admin (password)", "via": "password"}
                        FAILS.pop(ip, None)
                    event("good", f"admin login from {ip}")
                    self.json(200, {"ok": True, "csrf": csrf}, {
                        "Set-Cookie": f"brc={tok}; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age={SESSION_TTL}"})
                else:
                    with LOCK:
                        FAILS[ip] = [n + 1, t0]
                    event("warning", f"failed login from {ip}")
                    time.sleep(1)
                    self.json(401, {"error": "wrong password"})
                return
            tok, s = self.session()
            if not s:
                self.json(401, {"error": "login required"})
                return
            if not hmac.compare_digest(self.headers.get("X-CSRF", ""), s["csrf"]):
                self.json(403, {"error": "bad CSRF token"})
                return
            if path == "/api/logout":
                if getattr(self.server, "gw", False):
                    with LOCK:
                        GW_SESSIONS.pop(tok or "", None)
                    self.json(200, {"ok": True}, {"Set-Cookie": f"__Secure-brg=; Path={gw_base()}/; Secure; HttpOnly; SameSite=Strict; Max-Age=0"})
                    return
                with LOCK:
                    SESSIONS.pop(tok or "", None)
                self.json(200, {"ok": True}, {"Set-Cookie": "brc=; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=0"})
                return
            if path == "/api/action":
                if s.get("role") != "admin":
                    self.json(403, {"error": "view-only access: ask a survivability admin"})
                    return
                out = do_action(self.body())
                self.json(200, {"ok": True, "result": out})
                return
            self.json(404, {"error": "not found"})
        except PermissionError as e:
            self.json(403, {"error": str(e)})
        except (ValueError, KeyError) as e:
            self.json(400, {"error": str(e)})
        except Exception as e:
            self.json(502, {"error": str(e)[:200]})


class Redirect(BaseHTTPRequestHandler):
    """Port 80: send everyone to HTTPS (status.lan -> the public status page)."""

    def log_message(self, *a):
        pass

    def do_GET(self):
        host = (self.headers.get("Host") or "10.40.0.10").split(":")[0]
        if not all(ch.isalnum() or ch in ".-" for ch in host):
            host = "10.40.0.10"
        path = "/status" if host.startswith("status.") else (self.path if self.path.startswith("/") else "/")
        self.send_response(301)
        self.send_header("Location", f"https://{host}{path}")
        self.end_headers()

    do_HEAD = do_GET


def main():
    threading.Thread(target=identity_loop, daemon=True).start()
    threading.Thread(target=poller, daemon=True).start()
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(CONF["tls_cert"], CONF["tls_key"])
    if CONF.get("legacy_sso", False):
        try:
            sso = ThreadingHTTPServer((CONF.get("sso_listen", "10.40.0.10"), int(CONF.get("sso_port", 8081))), H)
            sso.sso = True
            sso.daemon_threads = True
            threading.Thread(target=sso.serve_forever, daemon=True).start()
        except OSError:
            pass
    if CONF.get("gateway_port"):
        # Remote access via BR2026 Caddy -> hub -> tunnel: TLS, Pocket ID sign-in.
        gw = ThreadingHTTPServer((CONF.get("gateway_listen", "10.40.0.10"), int(CONF.get("gateway_port", 8444))), H)
        gw.gw = True
        gw.daemon_threads = True
        gw.socket = ctx.wrap_socket(gw.socket, server_side=True)
        threading.Thread(target=gw.serve_forever, daemon=True).start()
    try:
        r = ThreadingHTTPServer((CONF.get("listen", "0.0.0.0"), 80), Redirect)
        threading.Thread(target=r.serve_forever, daemon=True).start()
    except OSError:
        pass
    srv = ThreadingHTTPServer((CONF.get("listen", "0.0.0.0"), int(CONF.get("port", 443))), H)
    srv.daemon_threads = True
    srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
