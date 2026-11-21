# Phase 2: OPNsense behind the edge (supervised, reversible)

> **STATUS 2026-11-21: APPLIED on cwwk02 and verified.** Done through OPNsense's API with `opn-phase2.py` (status / apply / sources / off / on),
> not by clicking, and the steps below are the manual equivalent with the corrections found on the real box:
> - the LAN's "Default allow" rule sits at sequence 1 and this OPNsense (26.7.8) has **no savepoint API**, so the policy rules are **floating quick rules**
>   on LAN + services (evaluated first, existing rules untouched) and the source list lives in alias `MP_SiteNets` (change it to move hosts on/off the edge);
> - DNS rides the tunnel through **static routes 1.1.1.1/32 + 1.0.0.1/32 via BR_EDGE plus Unbound forwarders** to them (no change to System DNS);
> - the edge's `site_open` gate must contain 10.47.0.0/29 (empty = locked = only DNS and the hub pass): `cwwk-addon.sh` now ships it open;
> - only NEW connections follow the rule: a long-lived pre-existing state keeps leaving through the old WAN until it closes (kill it in Firewall > Diagnostics > States);
> - **failure behaviour (reasoned, NOT tested):** BR_EDGE's monitor pings the edge container (10.47.0.1), which answers even when the tunnel is down, so a dead tunnel with the CT up leaves the gateway 'online' and the edge drops the traffic (no leak, no internet). If the edge CT itself is down the gateway goes offline and OPNsense's default is to drop the gateway from the rule, so traffic falls back to the direct WAN (the Spitz). Decide with Jake whether that fallback is wanted; to forbid it add a block rule after the policy rule. Rollback = `QUEZADA_START=yes python3 opn-phase2.py off`;
> - NIC: `qm set 100 -net3 virtio,bridge=vmbr2` hot-added `vtnet3` with no VM restart.
> Backups taken first: `~/Desktop/cwwk02-backups/opnsense-config-pre-multipath-*.xml` (config.xml) and the Proxmox snapshot `pre-multipath` of VM 100 (delete it with `qm delsnapshot 100 pre-multipath` once happy).

Phase 1 (`cwwk-addon.sh apply`) only adds the edge container. This phase makes OPNsense's LAN and services
traffic leave through it. **Do not start without:** (1) Phase 1 proven (hub lists cwwk02 with paths running,
`cwwk-addon.sh status` shows the hub exit address 89.167.30.202), (2) a person on site with a laptop on `nic3`
or the console, because remote access to this node rides OPNsense's own WAN + Tailscale, (3) a fresh backup of
VM 100 (`vzdump 100 --mode snapshot --storage local`), (4) Jake's go.

Design choice: **policy routing, not a new default gateway.** OPNsense itself (its Tailscale, updates) keeps its
WAN, so remote access never moves. Only LAN/services client traffic is sent to the edge. Undo = disable one rule.

## Values (site 2)
| | |
|---|---|
| transit bridge | `vmbr2`, 10.47.0.0/29: edge `10.47.0.1`, **OPNsense `10.47.0.2`**, controller `10.47.0.3` (later) |
| gateway name | `BR_EDGE` = 10.47.0.1 on interface `BR_TRANSIT` |
| DNS | forward to 1.1.1.1 / 1.0.0.1 only (the edge lets nothing else resolve) |
| NAT | LAN 172.22.100.0/24 and services 172.22.41.0/24 -> translated to 10.47.0.2 on `BR_TRANSIT` |

## Steps
1. **NIC (Proxmox host):** `qm set 100 -net3 virtio,bridge=vmbr2`. If the VM does not hot-add it, the NIC appears
   after a VM reboot, which is a short outage of every remote path: schedule it with the person on site.
2. **Interface:** Interfaces > Assignments: add the new `vtnet3`, name it `BR_TRANSIT`, enable, IPv4 static
   `10.47.0.2/29`. No upstream gateway on the interface page. Leave "block private networks/bogons" **off**.
3. **Gateway:** System > Gateways > Configuration: `BR_EDGE`, interface `BR_TRANSIT`, address `10.47.0.1`,
   **not** default, monitor 10.47.0.1 (the edge answers ping on `tr0`).
4. **NAT:** Firewall > NAT > Outbound: mode *Hybrid*; add two rules on `BR_TRANSIT`: source `172.22.100.0/24` and
   `172.22.41.0/24`, translate to interface address. (Without this the hub sees 172.22.x and drops it.)
5. **DNS:** System > Settings > General: DNS servers `1.1.1.1` (gateway `BR_EDGE`) and `1.0.0.1` (gateway
   `BR_EDGE`); untick "Allow DNS server list to be overridden by DHCP/PPP on WAN". Services > Unbound DNS >
   General: keep it as the LAN resolver; Query Forwarding: *Use System Nameservers*.
6. **Exceptions first** (Firewall > Rules > LAN and the services interface; ABOVE the tunnel rule), no gateway set:
   - source LAN net -> destination `100.64.0.0/10` (the tailnet) **pass, default routing.** Without this, replies to
     Tailscale users would be sent into the tunnel and "reach every Wi-Fi device over Tailscale" breaks.
   - source LAN net -> destination `RFC1918` + the two local nets: pass, default routing.
7. **The cutover rule** (this is the one switch): LAN (and later services) `source net -> any`, Advanced >
   Gateway = `BR_EDGE`, **pass**. Order: exceptions, then this rule.
8. **Prove it** (from a laptop on the LAN): `curl ifconfig.me` = 89.167.30.202; a tailnet device still reaches
   172.22.100.x; OPNsense still shows `online` in the tailnet; TAK/detection VMs reach the internet; hub list shows
   traffic. Run `cwwk-addon.sh status`.
9. **Roll back:** disable the rule from step 7 (LAN goes back out the old WAN at once). If OPNsense is unreachable:
   console or the laptop on `nic3`, or restore the VM 100 backup.

## Wi-Fi onto the LAN (optional, only if the Spitz Wi-Fi is wanted on this node)
The Spitz broadcasts its Wi-Fi as **VLAN 40** on the cable it shares with its modem LAN (nic2 now). Nothing on this node
serves VLAN 40, so Wi-Fi clients get no address yet. The clean fix keeps the 172.22.100.0/24 addressing and the tailnet route:
`qm set 100 -net4 virtio,bridge=vmbr10,tag=40` (a second leg for OPNsense on VLAN 40), then in OPNsense assign it and
**bridge it with LAN** (Interfaces > Devices > Bridge: members = the VLAN-40 vtnet + LAN). Wi-Fi clients then get LAN addresses
from the existing DHCP and are reachable over Tailscale like any LAN device. Verify the bridge on this OPNsense version first
(bridges pass traffic only with the member interfaces up and, on some versions, `net.link.bridge.pfil_member=1`).
The Spitz LAN port (eth1) is on the same VLAN 40, so a switch there joins the same LAN.

Not part of this phase: site lock, controller, a second carrier (the `ports` step in cwwk-addon.sh, later, with a modem on site).
Check the live state first, read-only, with `python3 ops/cwwk/install/quezada/opn-show.py` (uses
`~/Desktop/opnsense-api.txt`; GET requests only).
