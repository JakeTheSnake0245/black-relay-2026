# Black Relay Multipath ("Multithread")

Field-site kit that bonds every available internet connection (ISP, Starlink, cellular) into one
encrypted tunnel to the BR2026 hub, so the site keeps working when any single connection drops,
and nothing ever leaves the site unencrypted.

```
modems ──► CWWK site box ──► 6 TLS lanes per modem ──► BR2026 (Hetzner) Caddy :443 ──► hub ──► internet
 (any port)   br-edge / br-router / br-controller                       (/multithread-*)      89.167.30.202
```

## Layout

| path | what |
|---|---|
| `glorytun-fork/` | Patches to glorytun (multipath UDP tunnel): FEC, resequencing, path limits, security fixes. |
| `packaging/` | Builds the `black-relay` .deb / OpenWrt .ipk / hub container image (`build.sh`). `files/` holds the tunnel helper, watcher, dashboard (`br-dash`) and hub tools. |
| `edge/` | Site-edge tools on `br-edge`: `br-uplinks` (recognises the modem in each port; caps per device from `carriers.conf`), `br-ctl` (the controller's only commands), `br-selftest`, `br-lane-nurse`, firewall (`nftables.conf`). |
| `controller/` | Site controller (one web UI for the whole box: health, multipath, network, Wi-Fi, compute, services, setup, field guide), plus host tools: `br-hostinfo`, `br-port-roles`, `br-port-layout`, `br-rotate-secrets`, `br-controller-oidc`. Runbook: `controller/README.md`. |
| `site/cwwk01/` | As-built configuration of the first site box (secrets redacted), with a rebuild guide. Refresh with `deploy/snapshot-cwwk.sh`. |
| `deploy/` | `snapshot-cwwk.sh` (redacted as-built snapshot), `capture-cold-start.sh` (logs after a power-off test), `deploy-test.sh`. The BR2026 side is Ansible: `survivability/identity-stack/ansible/roles/black_relay_hub` and the edge Caddyfile. |
| `docs/` | Field card and site architecture (HTML sources; PDFs rendered from them), diagrams. |
| `gt-lab/`, `analysis/` | Lab scripts and capture-analysis tools used to tune the tunnel. |
| `docs/lab-results.md` | Lab measurements behind the defaults. |
| `docs/cold-start-test.md` | Full power-off and re-setup test: timings, what broke, what was fixed. |

## How it fits together

- **Site box (Proxmox, CWWK):** every physical port is on one VLAN-aware bridge. A modem in any port
  becomes its own uplink on `br-edge`; the Spitz's Wi-Fi (VLAN 40) works in any port; a laptop or
  switch in a port joins the site LAN. Containers: `br-edge` (tunnel, fail-closed egress),
  `br-router` (OpenWrt: DHCP, DNS, firewall for LAN 10.40.0.0/24 and services 10.41.0.0/24),
  `br-controller` (web UI).
- **Tunnel:** each modem carries 6 WebSocket/TLS lanes to `wss://headscale.l8s.dev` (only 443 is
  open on BR2026). glorytun mixes packets across all lanes (weighted by each modem's caps), puts
  them back in order at the hub, and the hub sends them on from Hetzner.
- **Remote access:** `https://headscale.l8s.dev/cwwk/` reaches the site controller through the
  hub and the tunnel; Pocket ID sign-in, LLDAP groups decide admin vs view-only.

## Secrets

Never in git. On the site host: `/root/black-relay/` (controller admin password, router root
password, Proxmox token, site join token). On BR2026: `/srv/black-relay/ws.env` (WebSocket path
prefix, also `black_relay_hub_ws_prefix` in SOPS) and site keys under `/srv/black-relay/etc/`.
The controller's Pocket ID client is stored with `br-controller-oidc`.

## Field use

Print `docs/field-card.html` (one page). The controller's Setup page and Field guide walk an
operator through cabling, power-up and the self-test.
