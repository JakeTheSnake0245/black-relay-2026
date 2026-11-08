# cwwk01: CWWK site box, as built

Point-in-time copy of the CWWK's configuration, taken by `survivability/cwwk/scripts/snapshot-cwwk.sh`
(time in `SNAPSHOT_TIME`). Re-run the script after any change on the box; it replaces
`host/`, `edge/`, `router/` and `controller/` and keeps this file.

**No secrets are in this tree.** The script redacts on the CWWK itself before anything is
copied: values show as `<REDACTED>`, SSH public keys as `<pubkey>`. The real secrets live
only on the Proxmox host in `/root/black-relay/` (root-only) and are never copied or committed.

## Layout

| path | what it is |
|---|---|
| `host/etc/network/interfaces` | Proxmox bridges: `vmbr10` all physical ports (VLAN-aware, STP; per-port untagged VLAN 100+i to `br-edge`, Wi-Fi VLAN 40 tagged), `vmbr1` site LAN, `vmbr2` edge↔router transit, `vmbr3` services |
| `host/etc/pve/lxc/10{1,2,3}.conf` | Container definitions: NICs, bridges, VLAN tags, MACs, features (`/dev/net/tun`, nesting) |
| `host/etc/systemd/system/br-*.service`, `host/usr/local/sbin/br-*` | Host tools: `br-port-roles` (client devices, rogue-DHCP guard), `br-port-layout` (any-port bridge), `br-hostinfo` (ports, temperatures, port blink), `br-controller-oidc`, `br-rotate-secrets` |
| `host/etc/sysctl.d/` | Host kernel settings |
| `host/tailscale.txt` | Tailnet name, address, tags (no Serve config: remote access goes through BR2026) |
| `host/pve-access.txt` | Proxmox role/ACL/token *IDs* the controller uses (no token secret) |
| `edge/etc/black-relay/` | Multipath tunnel: `br0.conf` (transport, lanes; `UPLINKS` is written by `br-uplinks`), `carriers.conf` (modem kinds + caps), tuning env, dashboard config |
| `edge/etc/nftables.conf` | Edge firewall: leak guard (nothing leaves the uplinks except the tunnel), forwarding rules |
| `edge/etc/systemd/network/`, `edge/etc/systemd/system/*.d/` | Port interfaces (DHCP, no pushed routes), wait-for-any-modem, `br-uplinks` before every tunnel start |
| `edge/usr/local/sbin/` | `br-uplinks` (modem detection), `br-ctl` (controller's forced-command verbs), `br-edge-routes` (fail-closed egress), `br-selftest`, `br-watchdog`, `br-lane-nurse` |
| `edge/root/.ssh/authorized_keys` | Forced-command entry for the controller key (key blob removed) |
| `router/uci-*.txt` | OpenWrt router: `uci export` of network, firewall, DHCP, wireless, system |
| `controller/etc/br-controller/config.json` | Controller config with every secret field redacted |
| `controller/deployed-sha256.txt` | Hashes of the deployed controller files, to compare with `survivability/cwwk/controller/` |

## Rebuilding the box from this

1. **Proxmox host:** install Proxmox VE. Restore `host/etc/network/interfaces` (adjust NIC names if
   the hardware differs; `br-port-layout unify` regenerates the port bridge from the NICs it finds)
   and `/etc/hosts` (`pve` → 10.40.0.2). Create containers 101–103 to match
   `host/etc/pve/lxc/*.conf` (start order 1, 2, 3; onboot):
   - 101 `br-edge`: Debian 13, unprivileged, nesting, `/dev/net/tun`.
   - 102 `br-router`: OpenWrt LXC image.
   - 103 `br-controller`: Debian 13.
2. **Edge (101):** install `black-relay-glorytun` 0.3.4+br6 or later (`survivability/multipath/packaging/build.sh`), join the
   hub with a site token (`black-relay-setup join <token>`, issued by the hub admin). Restore
   `edge/etc/` (nftables, networkd files, systemd drop-ins, `black-relay/` incl. `carriers.conf`) and
   `edge/usr/local/sbin/`; enable `br-lane-nurse`, `br-watchdog`, `br-dash`, `br-uplinks-recheck.timer`. Set `WSS_PREFIX` from
   the hub (`/srv/black-relay/ws.env` on BR2026).
3. **Router (102):** `uci import` each `router/uci-*.txt`, re-enter the redacted values, set the root
   password (`/root/black-relay/router-root.pw` on the host). The LAN zone must forward within the
   zone (Wi-Fi and wired site devices share it).
4. **Controller (103):** copy `survivability/cwwk/controller/` to `/opt/br-controller`, install the unit
   with `br-controller-network.conf` (same folder) as a drop-in, restore `config.json` and fill the
   redacted fields:
   - admin password hash: set it from Settings, or regenerate
   - Proxmox token secret and router password: run `br-rotate-secrets` on the host
   - Pocket ID client: run `br-controller-oidc` on the host
5. **Host tools and tailnet:** restore `host/` units and scripts (`br-port-roles`, `br-hostinfo`; sources in `survivability/cwwk/controller/`),
   `systemctl enable --now` them, SSH drop-in (keys only), and enroll Tailscale with a tag-only
   pre-auth key for `tag:proxmox-subnet-router`.
6. **Prove it:** controller **Setup → Run self-test**, everything green; then a cold start
   (`survivability/cwwk/scripts/capture-cold-start.sh`, `survivability/cwwk/docs/cold-start-test.md`).

## Where secrets come from (never in git)

| secret | source |
|---|---|
| Tunnel key (`KEY=` in `br0.conf`) | site join token from the hub (`black-relay-hub token <site>` on BR2026) |
| WebSocket path prefix | BR2026 `/srv/black-relay/ws.env`; SOPS `black_relay_hub_ws_prefix` |
| Controller admin password | `/root/black-relay/controller-admin.pw` (host) |
| Router root password | `/root/black-relay/router-root.pw` (host) |
| Proxmox API token | `/root/black-relay/pve-token.json` (host) |
| Pocket ID client secret | Pocket ID admin UI; stored with `br-controller-oidc` |
