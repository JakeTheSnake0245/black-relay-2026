# CWWK site box (cwwk01)

Proxmox host with three containers: **101 br-edge** (multipath tunnel), **102 br-router** (OpenWrt:
DHCP, DNS, firewall), **103 br-controller** (the web UI). Any modem, Wi-Fi access point, laptop
or switch goes in any port.

| | |
|---|---|
| Controller | https://headscale.l8s.dev/cwwk/ (anywhere, Pocket ID) · https://10.40.0.10 (on site) |
| Host shell | `ssh root@100.64.0.11` (tailnet), then `pct enter 101/102/103` |
| Field card | `docs/field-card.html` / `docs/Black-Relay-Field-Card.pdf` (print one page) |
| Runbook | `controller/README.md`: layout, ports, remote access, self-healing, hardening, host tools |
| Rebuild from bare metal | `as-built/cwwk01/README.md` |

## Folders

| path | what |
|---|---|
| `controller/` | Controller app (`app.py`, `index.html`, `status.html`) and the host tools (`br-hostinfo`, `br-port-roles`, `br-port-layout`, `br-rotate-secrets`, `br-controller-oidc`) |
| `as-built/cwwk01/` | Redacted copy of the box's live configuration (host, edge, router, controller) |
| `scripts/` | `snapshot-cwwk.sh` (refresh `as-built/`), `capture-cold-start.sh` (logs after a power-off test) |
| `docs/` | Field card, site architecture (HTML sources + PDFs), cold-start test |

The multipath parts that run on br-edge (`br-uplinks`, `br-ctl`, the tunnel package, the live
dashboard) are in `../multipath/`.

## Deploying a change

From this Mac (backups first, then push, then restart the one service):
```
scp <file> root@100.64.0.11:/root/
ssh root@100.64.0.11 'pct pull 103 /opt/br-controller/app.py /root/app.py.bak && pct push 103 /root/app.py /opt/br-controller/app.py && pct exec 103 -- systemctl restart br-controller'
```
Edge files go to CT 101 (`/usr/local/sbin/`, dashboard page `/usr/share/black-relay/dash/index.html`),
host tools to `/usr/local/sbin/` on the host. Anything that can cut the network (bridges, the
tunnel) runs detached, and cables are never moved until the change is verified running.
Afterwards: `scripts/snapshot-cwwk.sh` so `as-built/` matches.

## Current state (2026-11-08)

Ports: nic0 Starlink, nic1 empty, nic2 ISP (travel router), nic3 Spitz (Wi-Fi + cellular).
18 lanes. Exit IP 89.167.30.202.
