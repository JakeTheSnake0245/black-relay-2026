# The Spitz (GL.iNet GL-X3000) on cwwk01, as built 2026-11-20

Firmware 4.8.3 (OpenWrt 21.02). Not snapshotted by script (SSH needs a cable straight into its WAN port; the edge only lets site
devices open its web admin on 80/443). The admin password is not stored anywhere in this repo.

## Cabling (since 2026-11-20 ~16:43)
| Spitz port | goes to | carries |
|---|---|---|
| **WAN (eth0, 2.5G)** | CWWK `nic3` | trunk: untagged = the modem LAN `192.168.9.0/24` (the CWWK treats the Spitz as modem kind `spitz`, gateway 192.168.9.1) + **VLAN 40** = the site LAN |
| **LAN (eth1)** | a switch / any device | site-LAN **access** port: gets 10.40.0.x from the CWWK router, exits through the tunnel like Wi-Fi |
| Wi-Fi 2.4 / 5 GHz | clients | SSIDs `BR_2026_2` / `BR2026_5`, bridged into the site LAN (no DHCP on the Spitz) |
| SIM slot 2 | T-Mobile LTE | the Spitz's own uplink: rsrp about -87, sinr 11; shows as a second public IP (Cogent 38.52.195.58) at the hub |

Never connect a switch on the Spitz LAN port back to the CWWK: `br-site` has no STP, that is a loop.

## UCI that differs from the factory/`spitz-setup.sh` state (`/etc/config/network`)
- `network.site_vlan` (8021q): ifname **eth0**, vid 40, name `eth0.40`  (was eth1)
- `network.site_br` (bridge `br-site`): ports **`eth0.40` + `eth1`**
- `br-lan` device: ports **`eth0`** only (the untagged modem LAN, 192.168.9.1/24)
- wireless `wifi2g` / `wifi5g`: network `site`, unchanged
- backups on the Spitz: `/etc/config/network.bak-wanport-20261120-163648`, `/root/network.before-wanport`
Rollback: cable a laptop into the Spitz WAN port (it is br-lan), `cp /etc/config/network.bak-wanport-* /etc/config/network; reboot`.

## What the edge sees
nic3 carries VLAN 40 (site LAN) and the Spitz modem LAN as `up3` (192.168.9.107 via 192.168.9.1, kind `spitz`, caps 1000/1000 in `carriers.conf`). Hub: 12 paths running (6 lanes x 2 carriers: venue ISP on nic1, Spitz on nic3).
