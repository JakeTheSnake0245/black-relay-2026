# Black Relay — packages

Installable builds of the glorytun fork (`../glorytun-fork/`). One static
binary (musl + libsodium linked in), so the same build runs on Debian,
Ubuntu and OpenWrt with no library dependencies.

| file (in `../dist/`) | install on |
|---|---|
| `black-relay-glorytun_0.3.4+br6_amd64.deb` | site edges (CWWK `br-edge`), any x86_64 Debian/Ubuntu |
| `black-relay-glorytun_0.3.4+br6_arm64.deb` | arm64 Debian/Ubuntu (Hetzner CAX, lab VMs) |
| `black-relay-glorytun_0.3.4-br6_x86_64.ipk` | OpenWrt x86_64 |
| `black-relay-debug_0.3.4+br6_all.deb` | test/debug: per-interface capture + verification (see `debug/README.md`) |
| `black-relay-debug-0.3.4+br6.tar.gz` | `br-verify` + Wireshark dissector for the Mac |
| `black-relay-image_*.tar.gz` | the BR2026 hub container (`survivability/identity-stack/ansible/roles/black_relay_hub`) |

Production today: the hub runs as a container on BR2026 behind Caddy (HTTPS 443 only); sites run
the `.deb` on `br-edge` with `TRANSPORT=wss` (Use 2b). The OMR route (Use 3) is kept for reference
only.

Installing a package **starts nothing, enables nothing, and replaces no
binary**. The fork sits at `/usr/lib/black-relay/glorytun` beside whatever
glorytun is already there.

**Upgrading:** upgrade both ends in the same window. From br4, control
messages carry a role byte that br3 and older cannot read. Upgrading the
`.deb` restarts running `black-relay@` tunnels so they pick up the new binary.

## Build

    packaging/build.sh                    # macOS or Linux; needs zig, git, curl, python3, make
    ARCHES=x86_64 packaging/build.sh      # one arch

Pins `ysurac/glorytun@203c5f2` (what OMR ships) and libsodium 1.0.20
(sha256-checked), applies the fork patches `0001`–`0003` (`../glorytun-fork/`), runs the FEC
codec self-test, and writes `dist/` + `SHA256SUMS`.

## What's in it

| path | what |
|---|---|
| `/usr/lib/black-relay/glorytun` | the fork (static) |
| `/usr/sbin/glorytun-br` | wrapper: loads `/etc/black-relay/black-relay.env`, runs the fork |
| `/usr/sbin/black-relay-switch` | point OMR's `glorytun-udp` at the fork and back (rollback) |
| `/usr/sbin/black-relay-keygen` | make a tunnel key (mode 600) |
| `/etc/black-relay/black-relay.env` | runtime switches: `GT_SCHED`, `GT_RESEQ*`, `GT_HP`, `GT_FEC` |
| `/usr/share/black-relay/analysis/` | `relay-probe.py`, `lane-stats.py` |
| *deb only* `/usr/sbin/black-relay-lab` | 3-lane netns lab against the installed fork |
| *deb only* `black-relay-setup` | one-command server/client setup, `join <token>` for field sites, `doctor` health check |
| *deb only* `black-relay-hub` | many sites into one Hetzner hub: `add`, `token`, `list`, `remove` |
| *deb only* `black-relay@.service` + `/usr/lib/black-relay/tunnel` | standalone tunnel (no OMR), per-uplink source routing |
| *deb only* `black-relay-watch@.service` | re-ups a site tunnel when an uplink gets, loses or changes its address/gateway |

## Use 1 — test server

A throwaway VPS, both ends in network namespaces. No second host, no firewall change:

    sudo apt install ./black-relay-glorytun_0.3.4+br6_amd64.deb
    sudo black-relay-lab up
    sudo black-relay-lab probe 10          # report: recv/lost/ooo/depth/latency
    sudo black-relay-lab spike on; sudo black-relay-lab probe 10; sudo black-relay-lab spike off
    glorytun-br bench                      # real crypto ceiling on this CPU
    sudo black-relay-lab down

Edit `/etc/black-relay/black-relay.env` and re-run `down`/`up` to A/B the switches.

## Use 2 — standalone tunnel: Hetzner VPS ⇄ local multi-uplink box (no OMR)

Check the CPU type on each box first: `dpkg --print-architecture` gives `amd64` or `arm64`.

**Hetzner (server):**

    scp dist/black-relay-glorytun_0.3.4+br6_amd64.deb root@HETZNER:/tmp/
    ssh root@HETZNER
    apt install /tmp/black-relay-glorytun_0.3.4+br6_amd64.deb
    black-relay-setup server            # key + /etc/black-relay/br0.conf + starts black-relay@br0

Then open **UDP 5000 inbound** yourself (Hetzner Cloud firewall and/or
`ufw allow 5000/udp`). The setup prints the exact `scp` for the key.

**Local box (client):** run `ip -br addr` to get the uplink interface names, then:

    scp root@HETZNER:/etc/black-relay/br0.key ./br0.key
    sudo apt install ./black-relay-glorytun_0.3.4+br6_amd64.deb
    sudo black-relay-setup client --server HETZNER_IPV4 --key ./br0.key \
         --uplink enp2s0:300 --uplink enp3s0:150 --uplink wwan0:40
    ping 10.255.0.2
    sudo black-relay-setup status

`--uplink IF:MBIT` takes the interface and its real upload capacity in
Mbit/s. At every start the tunnel reads each uplink's current IPv4 and
gateway. Each uplink gets its own routing table (7100, 7101, ...) and a
`from <addr>` rule, so each path really leaves through its own link. An
uplink with no DHCP default route needs its gateway: `--uplink eth3:100:192.168.8.1`.
An uplink without an address yet is skipped and the others come up. After a
lease change, run `systemctl restart black-relay@br0`. Stopping the service
removes the rules.

Measure: on Hetzner `python3 /usr/share/black-relay/analysis/relay-probe.py recv --listen 10.255.0.2:9999`,
on the local box `python3 /usr/share/black-relay/analysis/relay-probe.py send --to 10.255.0.2:9999 --echo`,
and `lane-stats.py <if1> <if2> <if3> =br0` to watch the split.

This gives an encrypted bonded overlay link (10.255.0.1 ⇄ 10.255.0.2). Routing
site traffic through it (forwarding/NAT on Hetzner) is a separate, deliberate
step. The package changes no routing beyond the per-uplink rules above, and
no firewall rules.

**Moving it to the CWWK later:** the Proxmox host must keep no IP on uplink
VLANs 10/20/30. Run the client inside a VM that owns the VLAN sub-interfaces,
using the same `black-relay-setup client` with those interface names. Or go
the OMR route (Use 3).

## Use 2b — many field sites into one Hetzner hub

A glorytun process serves exactly one peer. So the hub runs one instance
per site, each with its own key, UDP port, tun device and /30. One command
on each side:

**Hub (once):** install the `.deb`, then open the site port range
**UDP 5001–5250** yourself (Hetzner Cloud firewall and/or `ufw allow 5001:5250/udp`).

**Per site, on the hub:**

    sudo black-relay-hub add alpha                       # or: add alpha --lan 192.168.40.0/24
    # -> site alpha: index 1, UDP 5001, hub 10.255.1.1 <-> site 10.255.1.2
    # -> brj1.QlJfU0lURT1h...   (join token: holds the site key, treat as secret)

**On the site** (deb installed, uplinks cabled):

    sudo black-relay-setup join brj1.QlJfU0lURT1h...     # uplinks auto-detected, rate auto
    sudo black-relay-setup join brj1... --uplink enp2s0:300 --uplink enp3s0:150 --uplink wwan0:40
    ping 10.255.1.1

Without `--uplink`, every interface that holds a default route becomes an
uplink with `rate auto` (glorytun's rate detection, capped at 1 Gbit). Measured
fixed rates are better once you know them. Re-running `join` with
`--force` rewrites the config. `black-relay-hub list` shows every site's port,
overlay address, service state and live path count. `remove <site>` stops a
site and deletes its key.

| site N | UDP port | hub address | site address | hub tun |
|---|---|---|---|---|
| 1 | 5001 | 10.255.1.1 | 10.255.1.2 | br-alpha |
| 2 | 5002 | 10.255.2.1 | 10.255.2.2 | br-bravo |
| ... up to 250 | 5000+N | 10.255.N.1 | 10.255.N.2 | br-&lt;site&gt; |

**First-run check, either end:** `sudo black-relay-setup doctor` (site) or
`sudo black-relay-hub doctor` (every hub site). It checks the binary, config,
key permissions, service, clock sync, tunnel address, each uplink's
address, routing rule and hub reply (with RTT), a ping through the tunnel,
and whether `GT_RESEQ_MS` covers the measured lane spread. It prints
ok / WARN / FAIL with the fix for each, and exits non-zero on any FAIL.

**Unattended stability:**
- `join` and `client` also enable `black-relay-watch@br0`. When an uplink
  gets an address after boot (Starlink up late), renews to a new one, or
  changes gateway (SIM swap), the tunnel re-ups within ~8 s.
- Restarts and Node 01 → Node 02 failover resume immediately. Sequence
  numbers continue across processes, so the hub never mistakes the new
  sender for a replay.
- Scatter skips a lane that trails the fastest by more than 60 % of the
  hold (`GT_SCATTER_BUDGET_MS`) until it recovers. A Starlink handoff no
  longer drops that lane's share.

`--lan` routes the site's LAN through its tunnel on the hub (route only;
forwarding/NAT stay a separate decision). For the field, the token can go
on the same USB stick as the `.deb`. Both CWWK nodes of one site use the
**same** token: one site identity, active/standby.

## Debugging and verification

`black-relay-debug` is a separate package: per-interface captures on both
ends, a checker that proves each packet left through the right uplink and
arrived, and an annotated `.pcapng` for Wireshark. See `debug/README.md`.

    hub$  sudo br-capture --name site-alpha --seconds 60
    site$ sudo br-capture --seconds 60
    br-verify ./br-capture-site-* --peer ./br-capture-hub-* --key br0.key

## Use 3 — OMR pair (historical; superseded by the hub container + Use 2b)

The fork's data wire format differs from stock: flip **both ends in the same
window**. Do not do this without an explicit go-ahead. Do it only after
Phases 5/5b have passed.

OMR server VM (Hetzner):

    sudo apt install ./black-relay-glorytun_0.3.4+br6_amd64.deb
    sudo black-relay-switch status                 # finds OMR's glorytun-udp
    sudo black-relay-switch fork                   # stock kept as <path>.stock
    systemctl list-units 'glorytun*'               # restart the one(s) shown

OMR router VM (Node 01, then Node 02 standby):

    opkg install /tmp/black-relay-glorytun_0.3.4-br6_x86_64.ipk
    black-relay-switch fork
    /etc/init.d/glorytun-udp restart

Rollback on either end: `black-relay-switch stock`, restart the tunnel.
Removing the package also restores stock automatically.

Notes:
- OMR keeps its own service, config and path tracker. The switch only
  changes which binary it executes. `glorytun-br` adds the `GT_*` knobs
  from `black-relay.env`.
- An OMR update that reinstalls `glorytun-udp` replaces the symlink with
  stock. Check `black-relay-switch status` after updates.
- `GT_HP` must match on both ends. Each end's `GT_SCHED` shapes what it
  sends; `GT_RESEQ` reorders what it receives.
- OpenWrt has no python3 by default. For the analysis tools, run
  `opkg install python3-light`, or run them from the server end.
