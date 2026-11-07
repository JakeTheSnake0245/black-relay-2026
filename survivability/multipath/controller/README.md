# CWWK site box: layout and runbook

Internet ⇄ **br-edge** (multipath) ⇄ **br-router** (OpenWrt) ⇄ LAN / Wi-Fi / services.
One web UI for everything: **br-controller**.

## Layout (Proxmox host `pve`)

| | what | addresses |
|---|---|---|
| CT 101 `br-edge` | Multithread: bonded tunnel to the BR2026 hub over HTTPS 443 (6 WebSocket lanes per uplink, per-packet weighted mix). Uplinks only. Fail-closed: nothing but the lane TLS to 89.167.30.202:443 and DHCP leaves a raw uplink. | up0 = nic0 (travel router / ISP), up1 = nic1 (Starlink), up2 = nic2 (Spitz, untagged 192.168.9.0/24); transit `tr0` 10.39.0.1/30 |
| CT 102 `br-router` | OpenWrt 25.12 + LuCI: DHCP, DNS, firewall. No NAT (the hub routes the site ranges). | uplink 10.39.0.2 → br-edge; LAN 10.40.0.1/24 (nic3 + Spitz Wi-Fi on VLAN 40); services 10.41.0.1/24 |
| CT 103 `br-controller` | Single web UI: health, multipath, network, Wi-Fi, compute, services (Frigate / TAK / sensors slots). | https://10.40.0.10 · tailnet https://100.64.0.11 |
| host | Proxmox, Tailscale (100.64.0.11, tag:proxmox-subnet-router). Default route via br-router. | LAN 10.40.0.2; management-only 192.168.8.205 |

Spitz (GL-X3000, GL.iNet 4.8.3): Wi-Fi (both SSIDs) bridged to VLAN 40 on its LAN port, no DHCP on it.
Its untagged LAN 192.168.9.1/24 is the uplink network for br-edge `up2`. Backups of its original
config on the Spitz: `/etc/config/{network,wireless,dhcp}.bak-blackrelay`.

## Web UIs

| UI | URL | login |
|---|---|---|
| Controller | https://headscale.l8s.dev/cwwk/ (remote, anywhere: Pocket ID sign-in) · https://10.40.0.10 (site LAN) | Pocket ID: LLDAP `survivability` = admin, `headscale-users` = view. Site LAN only: admin password `/root/black-relay/controller-admin.pw` on the Proxmox host (break-glass when the tunnel or Pocket ID is down) |
| Router (LuCI) | https://10.40.0.1 (LAN) | root: `/root/black-relay/router-root.pw` on the Proxmox host |
| Multipath live dashboard | inside the controller (Multipath page) | controller sign-in |
| Proxmox | https://10.40.0.2:8006 | root |

All certificates are self-signed (LAN). Change the controller password in Settings.

## Least privilege

- Controller → Proxmox: API token `br-controller@pve!ui`, role `BlackRelayController`
  (VM.Audit, VM.PowerMgmt, Sys.Audit, Datastore.Audit). Secret: `/root/black-relay/pve-token.json`.
- Controller → multipath: SSH key forced to `/usr/local/sbin/br-ctl` on br-edge, from 10.40.0.10 only,
  `restrict` (no shell / PTY / forwarding). Verbs: status, set-sched, set-hold, set-lanes, set-caps,
  restart-tunnel, spitz.
- Containers 101/102/103 are protected in the controller: start only, never stop.

## Multithread knobs (br-edge)

`/etc/black-relay/br0.conf`: `UPLINKS="up0:100/220 up1:7/150 up2:5/20"` (TX/RX Mbit, weights),
`TRANSPORT=wss`, `WSS_LANES=6`. `/etc/black-relay/black-relay.env`: `GT_SCHED=random`,
`GT_RESEQ_MS=400`, `GT_FEC=0`, `GT_KEEPALIVE_MS=200`. Hub side (BR2026,
`/srv/black-relay/etc/black-relay.env`) mirrors scheduler/hold and sets `GT_PASSIVE_TIMEOUT_S=30`.
Rollback to raw UDP: `cp /etc/black-relay/br0.conf.udp-bak /etc/black-relay/br0.conf` (needs a UDP port on the hub).

## Adding a service

Put its container/VM on `vmbr3` (10.41.0.0/24, DHCP from br-router, or static), then in the
controller → Services → Add (or Edit a placeholder): admin URL, health URL (`https://…` or
`tcp://host:port`), tick Deployed. It then counts toward overall site health.
LAN → services is allowed; services → LAN is not; services → internet goes through the tunnel.

## Field aids (added 2026-11-07)

| what | where |
|---|---|
| Fix-it panel (plain-language problems + numbered steps) | controller → Health (`problems()` in app.py) |
| Port map with live cable links + Blink port (ethtool -p, 15 s) | controller → Health / Setup; host helper `br-hostinfo` (10.40.0.2:8091, answers 10.40.0.10 only) |
| One-button self-test (cable, address, modem ping, lanes, hub, DNS, exit, leak guard) | controller → Setup; edge `br-ctl selftest` → `/usr/local/sbin/br-selftest` |
| Public status page for end users (no login, no addresses) | `https://status.lan` (`/status`, `/api/public`) |
| Easy names | router DNS: controller.lan, status.lan, router.lan, proxmox.lan; port 80 redirects to HTTPS |
| Field guide (troubleshooting, safe-to-press, glossary) | controller → Field guide |
| Printable one-page card | `Black-Relay-Field-Card.pdf` (source `docs/field-card.html`) |

Tailscale devices resolve DNS through the tailnet, so `.lan` names only work for devices without
Tailscale; use the IP addresses there (or add Headscale split DNS for `lan`, a tailnet change).

## Remote access: https://headscale.l8s.dev/cwwk/ (Pocket ID)

Published like the other BR2026 services: BR2026 Caddy (Let's Encrypt, public) → `multithread:8444`
(hub container, `br-supervise publish` from `/srv/black-relay/etc/publish.conf`: DNAT to the site,
SNAT to the tunnel address 10.255.1.1) → tunnel → edge (`/etc/nftables.conf`, one rule) → router
(`firewall.br_remote_ctl`) → controller gateway listener `https://10.40.0.10:8444`. Caddy pins the
controller's own certificate. The listener only accepts 10.255.1.1 and requires a Pocket ID sign-in
(code + PKCE); access needs a controller group in both the LLDAP snapshot and Pocket ID (role = lower
of the two). Password sign-in and the public status page are refused there. LAN password
(`https://10.40.0.10`) stays as break-glass when the tunnel or Pocket ID is down.

| piece | where |
|---|---|
| Pocket ID client | callback `https://headscale.l8s.dev/cwwk/oidc/callback`; stored in controller config `oidc` via `ssh -t root@100.64.0.11 br-controller-oidc` |
| BR2026 | Caddy site in `roles/edge/templates/Caddyfile.j2`, publish list `black_relay_hub_publish` (role) |

## Ports: any cable, any port

All physical ports are on one VLAN-aware bridge (`vmbr10`, spanning tree on, the CWWK is root).
Port *i* has its own untagged VLAN 100+*i* to `br-edge` up*i* (a modem there becomes its own uplink;
`br-uplinks` + `/etc/black-relay/carriers.conf` recognise ISP / Starlink / Spitz and set its caps),
and the Wi-Fi VLAN 40 is allowed tagged on every port to `br-router` (the Spitz works anywhere).
`br-port-roles` (host) moves a port's untagged VLAN to the site LAN when a laptop or switch is
plugged in instead of a modem (only if no modem answers there within ~45 s). Tools on the host:
`br-port-layout status|unify|confirm|rollback`, `br-rotate-secrets`. On the edge: `br-uplinks`,
`br-lane-nurse` (re-dials a modem's stuck lanes), `br-watchdog`.

## Hardening (2026-11-07)

SSH is key-only on the host and the controller (console fallback: Proxmox web UI shell). No
tailnet forwarders or Tailscale Serve: remote access is only `https://headscale.l8s.dev/cwwk/`
with Pocket ID. `rpcbind` is masked. Rotate the controller's Proxmox token and the router root
password with `br-rotate-secrets` (never prints secrets).
