# CWWK site box: layout and runbook

Modems (any port) ⇄ **br-edge** (multipath tunnel) ⇄ **br-router** (OpenWrt) ⇄ site LAN / Wi-Fi / services.
One web UI for everything: **br-controller**. Field operators only need the field card
(`../docs/Black-Relay-Field-Card.pdf`) and the controller's Setup page.

## Layout (Proxmox host `pve`)

| | what | addresses |
|---|---|---|
| host | Proxmox. All physical ports on `vmbr10` (VLAN-aware, spanning tree, the CWWK is root). Tailscale `100.64.0.11` (rides the tunnel). | site LAN `10.40.0.2` (`vmbr1`) |
| CT 101 `br-edge` | Recognises the modem in each port, carries 6 HTTPS lanes per modem to the BR2026 hub, bonds them (glorytun), fail-closed egress, live dashboard. | `up0`–`up3` = port VLANs 100–103 (nic0–nic3); transit `tr0` 10.39.0.1/30; overlay `br0` 10.255.1.2 |
| CT 102 `br-router` | OpenWrt + LuCI: DHCP, DNS, firewall. No NAT (the hub NATs). | wan 10.39.0.2 → br-edge; LAN 10.40.0.1/24 (`eth0` on `vmbr1` + Wi-Fi/client VLAN 40 `eth4` on `vmbr10`); services 10.41.0.1/24 |
| CT 103 `br-controller` | Web UI: health + fix-it, multipath, network, Wi-Fi, compute, services, setup + self-test, field guide. | https://10.40.0.10 · remote https://headscale.l8s.dev/cwwk/ |

**Ports: any cable, any port.** Port *i* has its own untagged VLAN 100+*i* to br-edge `up`*i*: a
modem there becomes its own uplink, recognised by `/etc/black-relay/carriers.conf` (Starlink: its
dish answers or a CGNAT address; Spitz: gateway 192.168.9.1; anything else: ISP) and given that
modem's speed caps. VLAN 40 (Wi-Fi / site LAN) is allowed tagged on every port, so the Spitz works
in any port. `br-port-roles` (host) switches a port to the site LAN when a laptop or switch is
plugged in (only if no modem answers there within ~45 s). One rule: never cable the same device
into two ports.

Spitz (GL-X3000): Wi-Fi (both SSIDs) bridged to VLAN 40 on its LAN port, no DHCP on it; its
untagged LAN 192.168.9.1/24 is its cellular uplink. Original config kept on the Spitz as
`/etc/config/{network,wireless,dhcp}.bak-blackrelay`.

## Web UIs

| UI | URL | login |
|---|---|---|
| Controller | https://headscale.l8s.dev/cwwk/ (anywhere) · https://10.40.0.10 (site) | Pocket ID: LLDAP `survivability` = admin, `headscale-users` = view. On site only: admin password (`/root/black-relay/controller-admin.pw` on the host), the break-glass when the tunnel or Pocket ID is down |
| Status (no login) | https://status.lan | – |
| Router (LuCI) | https://10.40.0.1 | root (`/root/black-relay/router-root.pw`) |
| Proxmox | https://10.40.0.2:8006 (site) · https://100.64.0.11:8006 (tailnet) | root |
| Modem admin pages | controller → Setup → Quick links (one per detected modem) | each modem's own |

On site, certificates are self-signed. `.lan` names don't resolve on devices running Tailscale
(MagicDNS first): use the addresses.

## Remote access path

BR2026 Caddy (`headscale.l8s.dev`, `/cwwk/*`, pins the controller's certificate) → hub container
(`multithread:8444`, `br-supervise publish`) → tunnel → br-edge → br-router (`firewall.br_remote_ctl`)
→ controller gateway listener `10.40.0.10:8444`. It accepts only the hub's tunnel address and
requires Pocket ID (code + PKCE); the role is the lower of the LLDAP snapshot and Pocket ID groups.
Password sign-in and the status page are refused there. Pocket ID client: callback
`https://headscale.l8s.dev/cwwk/oidc/callback`, stored with `br-controller-oidc` on the host.

## Multipath settings (br-edge)

| file | setting |
|---|---|
| `/etc/black-relay/carriers.conf` | modem kinds, how they're recognised, caps (TX/RX Mbit): ISP 100/150, Starlink 10/150, Spitz 5/20 |
| `/etc/black-relay/br0.conf` | `TRANSPORT=wss`, `WSS_LANES=6`; `UPLINKS` is written by `br-uplinks` before every tunnel start |
| `/etc/black-relay/black-relay.env` | `GT_SCHED=random`, `GT_RESEQ_MS=400`, `GT_FEC=0`, `GT_KEEPALIVE_MS=200` |
| tunnel helper | `GT_MTU=1400` for WebSocket lanes (fork patch 0003) |

Change caps, mixing, hold and lanes on the controller's Multipath page: one row per kind of
connection (Starlink, ISP, Spitz, and any kind added to `carriers.conf`) with upload and download
sliders on fixed steps (1–1000 Mbit, no typing), a live bar of the share each connected modem
would carry, Reset to defaults, and a before → after confirmation before the tunnel restarts.
A connection's share is its cap over the sum of the connected ones' caps; lower a connection's
caps to send it less of the site's traffic (e.g. a less trusted ISP). Hub side
(`/srv/black-relay/etc/black-relay.env` on BR2026) mirrors scheduler/hold, `GT_PASSIVE_TIMEOUT_S=30`.

## Self-healing

| what | how |
|---|---|
| cable moved, modem swapped, DHCP change | the tunnel restarts on any uplink change (at most once a minute; once per 5 min after 3), `br-uplinks` re-detects |
| modem recognised late (Starlink dish still booting at tunnel start) | `br-uplinks-recheck.timer` (every minute): a port that fell back to "ISP" whose own check now answers gets its real name and caps; the tunnel restarts once (at most every 5 min). It only ever upgrades from "ISP", never flips back |
| cable pulled from a modem port | the edge can't see the physical link (it sits behind the bridge), so the re-check ARPs each modem; no answer twice in a row drops the old lease and the tunnel moves off that port |
| a modem's lanes stuck (Starlink warm-up) | `br-lane-nurse` re-dials only that modem's stuck lanes, if it can reach the hub; backoff 30 s → 5 min |
| tunnel up but no data | `br-watchdog` restarts it after 3 failed hub pings |
| boot | containers start in order 101, 102, 103; edge waits for any one modem (max 20 s); ready ~2 min after power-on |

## Least privilege and hardening

- Controller → Proxmox: API token `br-controller@pve!ui`, role `BlackRelayController` (VM.Audit,
  VM.PowerMgmt, Sys.Audit, Datastore.Audit). Controller → br-edge: SSH key forced to
  `/usr/local/sbin/br-ctl` (`restrict`; verbs status, set-sched, set-hold, set-lanes, set-caps,
  restart-tunnel, spitz, uplinks, units, selftest). Containers 101–103 can't be stopped from the UI.
- br-edge: nothing but the lanes (TLS 443 to the hub, each pinned to its modem), DHCP and modem
  admin pages (site LAN only, private addresses only; plus the Starlink dish's own API, 9200 for
  the Starlink app and 9201 for the dish page, only once the dish is recognised) may use a modem; routes pushed by modems are
  ignored; site destinations always route via br-router. Dashboard and hub overlay: controller only.
- Host: bridge guard drops DHCP/DHCPv6 replies and IPv6 router adverts from any port except toward
  br-edge; spanning-tree root protection on ports. SSH key-only on the host and controller.
- No tailnet forwarders or Tailscale Serve: remote access is only the Pocket ID path above.
- Rotate the controller's Proxmox token and the router root password: `br-rotate-secrets` on the host
  (never prints secrets).

## Switches and the services VLAN

Every port carries three things: its own untagged VLAN (a modem → br-edge), **VLAN 40**
tagged (site LAN / Wi-Fi) and **VLAN 41** tagged (services). The router bridges VLAN 41 into
its `svc` interface (`br-svc` = `eth2` on vmbr3 + `eth5` on vmbr10 tag 41), so service
containers on the CWWK and devices behind a switch share 10.41.0.0/24 (DHCP .100–.199,
same firewall: LAN → services allowed, services → LAN blocked, internet via the tunnel).

A **switch** goes in any free port; the port becomes a client port (its untagged traffic is the
site LAN). On the switch: ports untagged / VLAN 40 = site LAN, ports on VLAN 41 = services
(cameras, sensors), uplink to the CWWK carries 40 and 41 tagged (or untagged = site LAN).
Controller → Network → **Devices by port** lists what the CWWK sees behind each port (from the
host's bridge, named by DHCP leases); **This is the switch** marks one, and the controller then
shows its port, address, admin page, devices behind it and a Blink button, and adds it to the
Health page (a missing switch is a fix-it item). Changing the switch's own settings from the
controller depends on the model and is not built yet.

## Site lock

The box **starts locked at every power-on** (and after Lock, or a reboot). Locked:
site devices get Wi-Fi/LAN addresses and this controller, and reach only the sign-in path at
BR2026 (443), the router's DNS and the modem/dish pages. No internet, no services, no tailnet.
The vault (encrypted volume `pve/br-vault`, mounted at `/mnt/br-vault`) is closed: it holds the
host's tailnet identity, the host secrets (`/root/black-relay` points into it) and the storage
of every service container (Proxmox storage `vault`). Host SSH and the Proxmox UI answer only
the controller.

**Unlock** (any one):
- **USB key:** plug the stick labelled `BRKEY` into the CWWK; ~10 s. Pull it out afterwards
  (a key left in counts as used; it must be re-inserted while locked to unlock again).
- **On site:** https://10.40.0.10 → admin password → vault passphrase.
- **Anywhere:** https://headscale.l8s.dev/cwwk/ → Pocket ID (admin) → vault passphrase.

**Lock:** Health page → Lock site (admins). Five wrong passphrases wait 15 minutes.

Owner: `br-lockd` on the host (`br-lockd status | lock`; console unlock: `br-lockd unlock`, then
type the passphrase). It also re-applies the edge gate if br-edge restarts.

**Service containers** that must stay off while locked: put their disks on storage `vault` and
give them the Proxmox tag `br-gated` (set onboot off). br-lockd starts them on unlock and shuts
them down on lock.

**Keys** (on the host, box unlocked):
- see the key slots: `cryptsetup luksDump /dev/pve/br-vault`
- lost USB key: `cryptsetup luksKillSlot /dev/pve/br-vault 1` (slot 1 is the USB key; give the
  passphrase when asked), then make a new stick (wipe it, label `BRKEY`, `BR-UNLOCK/cwwk01.key` =
  64 random bytes) and `cryptsetup luksAddKey /dev/pve/br-vault <keyfile>`
- new passphrase: `cryptsetup luksChangeKey /dev/pve/br-vault` (slot 0)
- the tunnel's own site key stays outside the vault on purpose: the locked box needs the
  tunnel to reach the sign-in page. Revoke it at the hub if the box is lost.

First-time setup: `br-vault-init` on the host (creates the vault, shows the passphrase once,
writes the USB key, moves the tailnet identity and secrets in).

## Health page

Top to bottom: overall state, **Services** (every service card, deployed first, with Open
buttons, plus any extra Proxmox container or VM; new ones appear by themselves), the fix-it
list, the five tiles, then **Site functions** folded into one line: the box's own parts
(multipath tunnel and its helpers, router, controller, host, Wi-Fi) with a live state each.
It names anything that needs attention without being opened, and a function that is down also
turns its tile amber or red. Sources: `br-ctl units` (edge), `br-hostinfo /units` (host), the
router's procd service list; refreshed every 30 s.

Colors follow the kind of modem everywhere (Multipath dashboard and the port cards):
Starlink blue, ISP orange, Spitz green, a second modem of the same kind violet. A modem keeps
its color in any port.

## Adding a service

Put its container/VM on `vmbr3` (10.41.0.0/24), then controller → Services → Add, or Import (JSON,
or one per line: `name | url | health | kind`). Links can be http(s), tcp, tls, rtsp, udp, ssh;
health checks http(s)://, tcp://, tls://, rtsp://. Mark it Deployed and it counts toward site
health. LAN → services is allowed; services → LAN is not; services → internet uses the tunnel.

## Host tools

| tool | what |
|---|---|
| `br-port-layout status\|unify\|confirm\|rollback` | the any-port bridge (with 15-min auto-rollback) |
| `br-port-roles` (service) | client-device detection, rogue-DHCP guard |
| `br-hostinfo` (service, 10.40.0.2:8091, controller only) | port links, temperatures, Blink port, host service states, devices behind each port |
| `br-controller-oidc` | store the Pocket ID client for the controller |
| `br-rotate-secrets` | new Proxmox token + router root password |
| `br-lockd` (service, 10.40.0.2:8092 TLS, controller only) | the site lock: vault, edge gate, tailnet, gated containers, USB key |
| `br-vault-init` | one-time: create the vault and the USB key |

Snapshot of the whole box (redacted): `../scripts/snapshot-cwwk.sh` → `../as-built/cwwk01/`.
After a power-off test: `../scripts/capture-cold-start.sh` (see `../docs/cold-start-test.md`).
