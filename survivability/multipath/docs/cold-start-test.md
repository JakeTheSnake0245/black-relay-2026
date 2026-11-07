# Cold-start test, CWWK site box (2026-11-07)

Everything powered off and unplugged, then set up again from the field card only, with cables in
different ports than before (Spitz in nic0, Starlink nic1, ISP nic2, nic3 empty).

**Result:** usable in 7 min 53 s from power-on. Any-port detection worked: each modem was
recognised in its new port and got its own caps; Wi-Fi worked with the Spitz in nic0.

## Found and fixed

| finding | effect | fix |
|---|---|---|
| br-router's LAN zone rejected forwarding inside the zone | Wi-Fi and client-port devices could reach the router but not the controller or Proxmox (`10.40.0.10`, `10.40.0.2`) | `firewall.lan.forward=ACCEPT` (OpenWrt default) |
| br-edge waited for every modem port to come up | with one port empty, boot (and the tunnel) stalled 2 min on `systemd-networkd-wait-online` | wait for any one modem, 20 s cap (`edge/wait-online-any.conf`) |
| br-controller started before its LAN address existed | crashed once at boot (`Cannot assign requested address`), recovered on restart 3 s later | start after `network-online.target` (`controller/br-controller-network.conf`) |
| Proxmox host: NFS block-layout helper starting with no NFS | log noise at boot | `nfs-blkmap` masked |
| tunnel MTU stuck at 573 | the tunnel takes the smallest MTU any lane has proved; lost probes on a lossy lane pinned it at the 576-byte floor, so large UDP (Tailscale direct, QUIC) couldn't pass | glorytun fork patch 0003 (`GT_MTU`), 1400 for WebSocket lanes; package 0.3.4+br6. Both ends now 1400; 1400-byte DF packets cross the tunnel |

## Open

| finding | effect | next step |
|---|---|---|
| Spitz: 2 of 6 lanes after the restart (6 of 6 before) | less Spitz capacity; the lane nurse keeps re-dialing | check the Spitz's own internet (SIM / WAN) on its admin page |

Expected boot with the fixes: about 5 minutes from power-on (modems' own boot dominates).
