# CWWK site box: layout and runbook

Modems (any port) ⇄ **br-edge** (multipath tunnel) ⇄ **br-router** (OpenWrt) ⇄ site LAN / Wi-Fi / services.
One web UI for everything: **br-controller**. Field operators only need the field card
(`docs/field-card.html`) and the controller's Setup page.

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

Change caps, mixing, hold and lanes on the controller's Multipath page. Hub side
(`/srv/black-relay/etc/black-relay.env` on BR2026) mirrors scheduler/hold, `GT_PASSIVE_TIMEOUT_S=30`.

## Self-healing

| what | how |
|---|---|
| cable moved, modem swapped, DHCP change | the tunnel restarts on any uplink change (at most once a minute; once per 5 min after 3), `br-uplinks` re-detects |
| a modem's lanes stuck (Starlink warm-up) | `br-lane-nurse` re-dials only that modem's stuck lanes, if it can reach the hub; backoff 30 s → 5 min |
| tunnel up but no data | `br-watchdog` restarts it after 3 failed hub pings |
| boot | containers start in order 101, 102, 103; edge waits for any one modem (max 20 s); ready ~2 min after power-on |

## Least privilege and hardening

- Controller → Proxmox: API token `br-controller@pve!ui`, role `BlackRelayController` (VM.Audit,
  VM.PowerMgmt, Sys.Audit, Datastore.Audit). Controller → br-edge: SSH key forced to
  `/usr/local/sbin/br-ctl` (`restrict`; verbs status, set-sched, set-hold, set-lanes, set-caps,
  restart-tunnel, spitz, uplinks, selftest). Containers 101–103 can't be stopped from the UI.
- br-edge: nothing but the lanes (TLS 443 to the hub, each pinned to its modem), DHCP and modem
  admin pages (site LAN only, private addresses only) may use a modem; routes pushed by modems are
  ignored; site destinations always route via br-router. Dashboard and hub overlay: controller only.
- Host: bridge guard drops DHCP/DHCPv6 replies and IPv6 router adverts from any port except toward
  br-edge; spanning-tree root protection on ports. SSH key-only on the host and controller.
- No tailnet forwarders or Tailscale Serve: remote access is only the Pocket ID path above.
- Rotate the controller's Proxmox token and the router root password: `br-rotate-secrets` on the host
  (never prints secrets).

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
| `br-hostinfo` (service, 10.40.0.2:8091, controller only) | port links, temperatures, Blink port |
| `br-controller-oidc` | store the Pocket ID client for the controller |
| `br-rotate-secrets` | new Proxmox token + router root password |

Snapshot of the whole box (redacted): `deploy/snapshot-cwwk.sh` → `site/cwwk01/`.
After a power-off test: `deploy/capture-cold-start.sh` (see `docs/cold-start-test.md`).
