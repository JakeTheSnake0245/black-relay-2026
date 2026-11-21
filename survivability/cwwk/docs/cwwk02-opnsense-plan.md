# THE QUEZADA BUILD: cwwk02, Black Relay multipath in front of OPNsense (plan, nothing applied yet)
> Jake named this the "Quezada build" on 2026-11-19. Node = cwwk02 (site 2). Code/notes may say cwwk02; the build name is Quezada.

> **REMIND JAKE (his request, 2026-11-19): the node's RAM is over-committed** (20 GiB of VM RAM on 15.7 GiB, swap 4.5/8 GiB in use).
> Raise it when he authorises the start, again before the cutover, and in the final proof. Options then: shrink VM 101/102 memory, or accept swap.

## Decisions answered 2026-11-19
1 IDs 110 (edge) / 111 (controller): yes. 2 no services CT, services go on VM 101: yes. 3 keep 172.22 addressing, any Wi-Fi AP device
must be routable through the tailnet (OPNsense keeps advertising 172.22.100.0/24 and 172.22.41.0/24). 4 no spare modem now; someone will
be on site later to test. 5 OPNsense via API key. 6 site lock waits until Jake has the box in hand. 7 Jake authorises the start.

Surveyed read-only on 2026-11-19 (root SSH to 172.22.100.2; no changes made). Local only (ops/ is not in the public repo).

## 1. What is on the node today

| | |
|---|---|
| Host | `cwwk02`, Proxmox VE 9.2.26 (Debian 13, kernel 7.0.14-pve), Intel N100 4 cores, 15.7 GiB RAM, 238 GB NVMe, 4x Intel I226-V (`nic0..nic3`). Standalone (no cluster). |
| Host network | `vmbr1` = LAN 172.22.100.2/24, gateway 172.22.100.5 (= OPNsense LAN), port `nic3` (no cable now). `vmbr2` = empty bridge, no ports (unused). `vmbr3` = services bridge, no ports. `vmbr10` = VLAN-aware port bridge, STP on, prio 0, vids 40 41 100-102, ports `nic0 nic1 nic2` (all PVID 1). **Already cwwk01's layout, on a 172.22 plan.** |
| Ports | `nic2` link up 1 Gb (the WAN today). `nic0`, `nic1`, `nic3` no link. |
| VM 100 | `cwwk02-opnsense-01` (OPNsense 26.7), 4 GiB, 2 cores. net0 -> `vmbr10` (WAN, untagged VLAN 1), net1 -> `vmbr1` (LAN 172.22.100.5), net2 -> `vmbr3` (services). No snapshot. |
| VM 101 | `cwwk02-ubuntu-01`, 8 GiB, 80 G, on `vmbr3`. ACL: group VM-Users (`detectionteam@pve`) -> it is the detection team's VM. A vzdump of it exists from today 17:32. |
| VM 102 | `cwwk02-tak-server`, 8 GiB, 80 G, on `vmbr3`, snapshot `baseline`. `takteam@pve` -> TAK team. |
| Subnets | LAN 172.22.100.0/24, services 172.22.41.0/24 (both advertised to the tailnet by OPNsense, tag:cwwk-02). |
| Remote access | Mac -> tailnet -> **OPNsense's Tailscale subnet route** -> vmbr1 -> host. The host itself has no Tailscale. |
| Memory | **Over-committed**: 20 GiB of VM RAM on a 15.7 GiB host (24 GB committed), 4.5 of 8 GiB swap in use, 1.4 GiB available. |
| Storage | `local-lvm` thin 141 G (26% used, 175 G already promised), VG free 16 G, `local` 70 G (16 G used). No CT templates present. |
| Other | No Black Relay anywhere (`/root/black-relay` absent). Root password SSH on, 2 keys. Clock not NTP-synchronised. `/etc/hosts` still says `192.168.150.10 cwwk02.home.arpa` (not on this box). PVE firewall off. |

## 2. What that changes versus the standard installer

1. **IDs collide.** Host tools hard-code edge=101, router=102, controller=103, services=104. 101/102 are VMs. -> Black Relay IDs must be configurable (proposal: edge **110**, controller **111**). No OpenWrt (router CT 102) at all.
2. **Bridges already exist and are in use** (vmbr1/2/3/10). The installer must *use* them, not create them. `vmbr2` is exactly the transit bridge we need; `vmbr10` is already the port bridge.
3. **Address plan differs.** The tools derive the site from `vmbr1 = 10.A.0.2/24`. Here it is 172.22.100.2. -> an explicit `site.env` replaces the derivation (cwwk01 keeps working by fallback).
4. **The edge is a no-NAT router-behind design**: OpenWrt does not masquerade; the edge's policy rule, the lock gate (`site_open` = 10.32.0.0/11) and the hub routes all assume site addresses are inside 10.32.0.0/11. cwwk02's LAN is 172.22.x. -> **OPNsense must NAT outbound on the transit link** (source becomes 10.47.0.2, inside 10.32/11). Nothing at the hub or in the edge routing needs to change, and the TAK/detection VMs keep their addresses.
5. **My own access (and every remote user's) rides on OPNsense's WAN.** Moving OPNsense behind the edge cuts that path until the tunnel is up. Needs a staged cutover and a physical fallback.
6. **RAM is the limiting resource.** br-edge + controller fit (about 0.3 GB real), the 4 GB services CT does not. VM 101 (detection) is the natural place for sf-dev services anyway.
7. **Hub side is unaffected** by 172.22: register site 2 normally (`hub-add-site.sh 2`), with the transit range only needed.

## 3. Target design

```
modems --nic0/nic1/nic2--> vmbr10 (VLAN 100/101/102 per port) --> br-edge CT 110 --tunnel--> BR2026 hub
                                                                   | tr0
                                         vmbr2 transit 10.47.0.0/29: edge .1  OPNsense .2  controller .3
                                                                   |
 OPNsense VM 100:  WAN  = new NIC on vmbr2  10.47.0.2/29, gateway 10.47.0.1, outbound NAT on
                   LAN  = vmbr1 172.22.100.0/24 (unchanged; nic3 -> Spitz as AP + laptops)
                   SVC  = vmbr3 172.22.41.0/24  (unchanged; VM 101 detection, VM 102 TAK)
 controller CT 111: eth0 vmbr1 172.22.100.10 (UI for the LAN), eth1 vmbr2 10.47.0.3 (talks to edge, hub remote access)
```
The Spitz is only an access point: Wi-Fi bridged into the OPNsense LAN through `nic3`. OpenWrt is not installed.

## 4. Phases (each is reversible; only 3 interrupts anything)

**0. Done.** Read-only survey (above).

**1. Build, no effect on the running box.** (a) BR2026: `sudo bash hub-add-site.sh 2` (transit /29). (b) Build the kit without OpenWrt/router image (template comes from `pveam` on the node, so cwwk01 is not needed). (c) Copy to the node. (d) New installer `cwwk-addon.sh` (survey, then apply):
   - writes `/etc/black-relay/site.env` (IDs, addresses, bridges, ports),
   - creates CT 110 br-edge (tr0 on vmbr2; up0/up1 on vmbr10 tags 100/101; temporary download NIC on vmbr1 with a free static address, removed afterwards), joins the hub, nft/leak guard in place,
   - gives only `nic0`/`nic1` their PVIDs (100/101). **nic2, OPNsense, VMs 101/102 untouched.**
   - creates CT 111 controller (LAN .10 + transit .3), Proxmox API token (read-only role), host tools, lock service in the open "setup" state.
   Test: a spare modem/hotspot in `nic0` -> tunnel up, `br-verify` edge and hub sections green. (If there is no spare modem, `up2` can share nic2's venue network instead: second MAC on VLAN 1; to be decided.)

**2. OPNsense prep (additive).** Proxmox: hot-add `net3` (virtio) to VM 100 on `vmbr2`. OPNsense (UI or API): new interface `BR_TRANSIT` 10.47.0.2/29, gateway `BR_EDGE` 10.47.0.1 (not default yet); hybrid outbound NAT for LAN and services on `BR_TRANSIT`; Unbound forwards to 1.1.1.1/1.0.0.1 (the edge lets only the router resolve, and only via those); port-forward TCP 8444 from the hub (10.255.2.1) to the controller; allow rules for the controller. The old WAN stays active.

**3. Cutover (window, ~10 min, someone with a laptop on `nic3`/keyboard on site).** Take a Proxmox backup of VM 100 first. Make `BR_EDGE` the default gateway in OPNsense (rollback = switch back). Check LAN/TAK/detection traffic exits through the tunnel (`br-verify`, hub egress address). Then move the nic2 modem to the edge (`nic2` PVID 102, edge `up2`) so nothing leaks past the edge. Auto-rollback timer as in cwwk01 (`br-port-layout`).

**4. Finish.** Spitz AP-only on `nic3` (adapted `spitz-setup.sh`); controller router panel in "status + link" mode; services from sf-dev go to VM 101 (br-svc variant, later); site lock **not** initialised until after the event (locked = the whole site has no tunnel after every reboot until an admin unlocks).

**5. Proof.** `br-verify` gets an OPNsense/addon mode (checks transit ping .2, NAT working, edge, hub, controller, security); output saved with the plan.

## 5. Code to write (nothing exists yet)

`cwwk-addon.sh` (survey/apply/rollback) and `site.env`; host tools read IDs/addresses from `site.env` (br-verify, br-svc, br-lockd, br-port-roles, controller app.py: about 40 spots) with the cwwk01 derivation as fallback; edge render for /29 + NAT source; kit variant without router; `hub-add-site.sh` transit-only option; `br-verify` addon mode; controller router provider `opnsense|none`; OPNsense checklist generator with the real addresses; AP-only Spitz script; tests against stub/sandbox like before.

## 6. Open decisions (recommendation first)

1. CT IDs: edge **110**, controller **111** (VMs 100-102 stay).
2. No services CT; services go on VM 101 later. (Saves 4 GB RAM.)
3. Keep 172.22 addressing; OPNsense NATs onto the transit link.
4. Test uplink before cutover: spare modem in `nic0`/`nic1`, or share nic2's venue network?
5. OPNsense changes: guided checklist (recommended) or API key?
6. Site lock after the event.
7. Cutover window and a person on site with a laptop (my access to this box goes through OPNsense).
8. Pre-existing issues to fix or leave: NTP not synced, stale `/etc/hosts`, memory over-commit (shrink VM 101/102 or accept swap), any public port-forwards on OPNsense's WAN (they would stop; the public exit becomes the hub).

## 7. Not verified

OPNsense internals (WAN DHCP/static, rules, Tailscale plugin config, any port-forwards, DHCP server on LAN); whether a spare modem exists; whether the venue network allows two MACs on nic2; hub registration for site 2 (not run); DHCP availability on vmbr1 for the temporary download NIC (fallback: a free static 172.22.100.x).

---
# UPDATE 2026-11-19 (evening): OPNsense + multipath check (read-only, nothing changed)

## Findings

**OPNsense (VM 100, "OPNsense 26.7")** - only what is visible without a login: UI on 443/80 answers (login page), DNS (Unbound) on 53 answers, **no SSH**, API path redirects (302) without a key. LAN 172.22.100.5, services side on vmbr3. **WAN = 192.168.77.150 (private, behind the venue router), untagged on nic2.** Its Tailscale: direct path to the Mac via 96.225.132.17 (the venue's public address), DERP `iad`, subnet routes 172.22.100.0/24 + 172.22.41.0/24 approved. Everything else (rules, NAT, DHCP, Tailscale plugin settings, port-forwards) needs the API key.

**nic2 is a VLAN trunk into a lab router (MAC aa:9c:6c:16:88:96), not a single modem.** Seen on it: untagged 192.168.77.0/24 (OPNsense WAN); tagged VLAN 1 (192.168.10.1), **101 (192.168.101.1), 102 (.102.1), 103, 104 (.104.1), 108**. vmbr10 only lets 40/41/100-102 through, so 103/104/108 are dropped (that is the 25k rx "dropped" counter). Possibly each VLAN is a separate test carrier (not confirmed: no DHCP or internet was probed; only passive listening was done).

**Live traffic:** OPNsense sends a steady ~21 Mbit/s of TCP/443 to 178.156.134.232 (Hetzner-range, 15-24 ms from the node; not confirmed what it is). The hub (Helsinki) is 115-120 ms away, so sending that flow through the tunnel would route it Atlantic-and-back. Decide whether it stays on the direct WAN.

**Path to the hub:** TCP 443 to 89.167.30.202 opens (0.12 s); ICMP path MTU >= 1500; RTT 115-121 ms; the host's own egress works (1.1.1.1 12-40 ms). The venue public IP is 96.225.132.17.

**Host problems that block the install:** DNS is dead (`/etc/resolv.conf` = 192.168.150.1, old network; `download.proxmox.com` does not resolve; OPNsense's resolver 172.22.100.5 works) -> apt/pveam/tailscale installs fail; chrony has no sources so the clock is unsynced (the time itself is correct today within seconds). Fix = point host DNS at 172.22.100.5 (a host change; needs go-ahead). `/etc/hosts` still lists 192.168.150.10. No Debian CT template on the node (kit supplies it or `pveam` after DNS is fixed).

**Kernel/tuning:** PVE kernel 7.0.14, lxc-pve 7.0.0-2, pve-container 6.1.18, AppArmor on, CPU N100 with AES, governor `performance`, rmem_max 4 MB (install raises to 8 MB), `fq_codel`/`cubic`, `/dev/net/tun` present, `nf_conntrack` not loaded on the host (installer must make sure it loads before the edge's nft rules). nic2 igc offloads on, ring 4096.

**Headscale ACL file on the hub** (`~/headscale-policy.hujson`) has no `cwwk-02` rule even though OPNsense is tagged `tag:cwwk-02` with approved routes, so the active policy lives elsewhere; check before the host joins the tailnet. hub-add-site needs sudo on the hub (jake is not in the docker group).

## Revised design (safer than the first draft)
Because nic2 is a trunk, the edge does not need nic2's modem moved. Instead:
- **OPNsense keeps its WAN on nic2 untagged** (192.168.77.x). Its Tailscale (= everyone's remote access) never moves, so there is no lockout risk at cutover.
- **br-edge (CT 110) attaches to the trunk VLANs as its uplinks** (e.g. up0 = VLAN 101, up1 = VLAN 102, up2 = VLAN 103...) via `vmbr10 tag=<vid>`; add vids 103/104/108 to nic2 as needed. The multipath tunnel can be tested **now, remotely, with no modem and no one on site**, if those VLANs have DHCP + internet. All carriers share nic2's 1 Gb and probably the same venue ISP, so this proves the mechanism and failover but not diversity.
- OPNsense gets a second WAN-side NIC on vmbr2 (transit /29, edge .1, OPNsense .2, controller .3) and a **gateway group**: LAN/services/Wi-Fi clients default through the tunnel (outbound NAT onto 10.47.0.2), the old WAN stays as fallback and for OPNsense itself. Policy rules can keep named destinations (e.g. 178.156.134.232) on the direct WAN.
- Spitz = AP only on nic3 -> OPNsense LAN 172.22.100.0/24, which OPNsense already advertises on the tailnet, so every Wi-Fi device is reachable over Tailscale with no extra routes.
- Not used on this node: br-port-roles / br-port-layout (they assume every port is on vmbr10 with its own PVID); per-port VLAN membership is set explicitly instead.

## Still needed from Jake
1. **OPNsense API key + secret** (System > Access > Users > a dedicated user `br-api` > API keys "+"; save the downloaded `apikey.txt` to `~/Desktop/opnsense-api.txt`, chmod 600). Read first; later needs privileges for interfaces, gateways, NAT, firewall rules, Unbound.
2. Are VLANs 101-108 on that trunk meant as test carriers, and may I send a harmless DHCP DISCOVER (no lease taken) on each to see which give an address?
3. What is the 21 Mbit/s flow to 178.156.134.232 and should it bypass the tunnel?
4. Go-ahead for the first tiny host change (host DNS -> 172.22.100.5) when you authorise the start.

---
# UPDATE 2026-11-19 (night): OPNsense config read from its disk + VLAN service probe (nothing changed)

Method: with root on the node, a temporary read-only thin snapshot of VM 100's volume was imported read-only (ZFS `zroot`) and `config.xml` read with secrets masked; snapshot/loop/pool were removed and verified gone afterwards. The VM was never written to. (The OPNsense config on disk was last saved 2026-11-09 21:12.)

## OPNsense 26.7.8_2, as configured
- Host `cwwk02-opnsense-01`, domain `internal`, UTC; SSH off (no SSH access), web UI https; user `root` had NO API key (an empty placeholder fooled the first read); one was created 2026-11-19, see the correction block at the end.
- **WAN** vtnet0 DHCP (v4 + dhcp6), block private + bogons on; **LAN** vtnet1 172.22.100.5/24; **OPT1** tailscale0; **OPT2** vtnet2 172.22.41.5/24 (services). No VLANs, no gateways defined, no static routes, no aliases, no WAN rules.
- **Firewall** rules (all that exist): LAN any (v4/v6), tailscale0 any, services any. NAT outbound = automatic; no port-forwards.
- **Tailscale plugin**: enabled, login server `https://headscale.l8s.dev`, advertises **172.22.100.0/24 and 172.22.41.0/24**, accept subnet routes + accept DNS on, SNAT on, no exit node. Wi-Fi/LAN devices are already reachable over the tailnet.
- **DNS**: Unbound on 53, **forwarding off (recursive resolver)**, system DNS 1.1.1.1 / 9.9.9.9. **The edge only lets the router resolve through 1.1.1.1/1.0.0.1 port 53**, so after cutover Unbound must forward to 1.1.1.1/1.0.0.1 (and 9.9.9.9 dropped) or the edge allow-list widened.
- ~~No DHCP server~~ WRONG, corrected below: dnsmasq DHCP serves the LAN (172.22.100.41-245); services (172.22.41.0/24) is static.
- Offloads (checksum/TSO/LRO) disabled in OPNsense; IDS/WireGuard/IPsec/OpenVPN off.

## The VLANs on nic2: services (probed with plain TCP connects through OPNsense)
Gateways answering **ping and DNS (TCP 53) and nothing else** (22/80/443/8080/8006 filtered): 192.168.77.1, 192.168.10.1 (VLAN 1), 192.168.101.1, 102.1, 103.1, 104.1, 108.1. One router serves them all (same MAC) and routes between them. Quiet hosts on VLAN 104 (192.168.104.167, .190) and 192.168.122.1 do not answer ping or any of those ports. **Not yet known: whether each VLAN hands out DHCP, which have internet, whether any is a different ISP.** (Passive hints: mDNS, UDP 10001 Ubiquiti-style discovery, NAT-PMP from OPNsense's Tailscale.)

## New items for the plan
1. Unbound -> forward to 1.1.1.1/1.0.0.1 (or widen the edge allow-list).
2. ~~DHCP for the Spitz AP~~ not needed: OPNsense dnsmasq already serves 172.22.100.41-245 on the LAN.
3. Black Relay should leave the Tailscale/LAN rules alone; the new transit NIC gets its own interface + gateway, with outbound NAT hybrid for LAN + services.
4. Rotate the node's root password after the work (it was shared in chat).

---
# CORRECTIONS + API KEY (2026-11-19, late)
- **API key created** on OPNsense `root` (the only user) via the UI's own endpoint, additive: keys before 0, after 1. Saved on the Mac at `~/Desktop/opnsense-api.txt` (mode 600; key+secret, never put in docs/memory). Tested with HTTP basic auth, no session: firmware status 200 (26.7.8_2), interface names 200. It is a ROOT-attached key = full control of OPNsense. Delete it (System > Access > Users > root > API keys) or replace it with a limited user's key when the work is done. Jake's condition ("only if the first key still works"): there was no first key on OPNsense, nothing existing was touched. Jake confirmed OPNsense uses the same root login as the node; the node password was shared in chat, rotate it afterwards.
- **DHCP exists**: dnsmasq (running) serves the LAN, range 172.22.100.41-172.22.100.245, no static hosts, 0 leases right now. Unbound still forwards `internal` to dnsmasq (127.0.0.1:53053). The Spitz as AP-only already gets DHCP and lands on 172.22.100.0/24 (advertised on the tailnet).
- Live state matches the Nov 9 config: WAN vtnet0 192.168.77.150/24 via 192.168.77.1 (gateway WAN_DHCP, no monitor), LAN 172.22.100.5/24, OPT2 172.22.41.5/24 (VM 101 is 172.22.41.10), tailscale0 100.64.0.20 (Tailscale 1.104.2, tailnet tail.l8s.dev), FreeBSD 15.1, only 4 real firewall rules (LAN/OPT1/OPT2 allow-any), 0 port-forwards, services running: dnsmasq, unbound, tailscale, ntpd, pf, syslog-ng.
- RAM note for the reminder: OPNsense uses ~1 GB of its 4 GB, so VM 100 could drop to ~2 GB to ease the host's over-commitment.

---
# ANSWERED 2026-11-19 (late): the two open questions

**VLAN carriers - DHCP probe (one DISCOVER per VLAN on nic2, made-up MAC 02:b7:..., no REQUEST so no lease taken; offers lapse by themselves).** Every VLAN has a DHCP server at its .1 that is also the gateway and DNS, 24 h leases, no MTU option:
| VLAN | network | note |
|---|---|---|
| 1 | 192.168.10.0/24 | domain `localdomain` |
| 101 | 192.168.101.0/24 | |
| 102 | 192.168.102.0/24 | |
| 103 | 192.168.103.0/28 | tiny pool (offered .9) |
| 104 | 192.168.104.0/24 | |
| 108 | 192.168.108.0/24 | |
All one router (same MAC), so very likely one ISP behind all of them. Still unverified: internet per VLAN and whether any is a separate uplink; the edge's own DHCP + tunnel test will show it. Candidate uplinks for br-edge: VLAN 101, 102, 104, 108 (/24s), 1; 103 only if a /28 is enough.

**The 21 Mbit/s flow - not a site application.** It is OPNsense's own Tailscale (source port 41641, STUN 3478 and TCP 443) talking to the Ashburn relay (iad = 178.156.134.232, Hetzner) carrying about 14.7 GB to the tailnet peer **`fedora` (100.64.0.4)**, relayed (no direct path). Timing matches the VM 101 (17:32) and VM 102 (18:56, 5.8 GB) vzdump backups made today, probably someone copying them off over the tailnet; not proven. A re-check showed it has stopped (VM NICs 0 kbit/s, no ssh sessions, nothing reading the dump files). So no site traffic needs a tunnel exemption: with the gateway-per-rule design only LAN/services internet traffic goes through the tunnel, while OPNsense's own Tailscale stays on its WAN.

---
# DECISION 2026-11-19: build multipath in place on cwwk02 (no VM move, no clone)
Jake confirmed: put the multipath onto cwwk02 itself. Phase 1 is **edge-only**: CT 110 br-edge on the trunk-VLAN uplinks, hub registration for site 2, `vmbr2` as the edge<->OPNsense link, one new NIC on OPNsense and a gateway for LAN/services traffic. Controller, site lock, services CT and OpenWrt are deferred (controller can be added afterwards). Start order once Jake says start: host DNS -> carrier test per VLAN -> edge + tunnel -> OPNsense cutover. Nothing has been applied yet.

---
# HUB BLOCKER FOUND 2026-11-19 (read-only on BR2026; Jake has passwordless sudo there, remember it)
The hub's `survivability-black-relay` container has been **crash-restarting every ~10.7 s since 2026-11-18 23:21 UTC** (8,700+ restarts), exactly when Jake unplugged/shut down cwwk01. Cause: `br-supervise` runs under `set -eu`; its data-plane watchdog (first run ~10 s after start, then every ~10 s) does `running=$(glorytun path ... | grep -c " running ")`, and `grep -c` exits 1 when a registered site has no running paths, which aborts the whole supervisor, so Docker restarts it. Reproduced in dash and bash (exit 1). **Any offline registered site takes the hub's tunnel service down for ALL sites**, so site 2 cannot stay up while cwwk01 is offline, and later any site going offline would do the same. Hub specs are fine (4 vCPU, 7.7 GB, idle); headscale/caddy/pocket-id are separate containers and unaffected. Site 2 is not registered (hub list shows only cwwk01, idx 1). Live headscale policy already has tag:cwwk-02 and its two subnets (so the earlier ACL worry is closed).
**Fix prepared, NOT applied:** `multipath/packaging/docker/br-supervise` (dev tree) now has `| grep -c " running " || true`; tested under the hub's dash (exit 0, loop continues). Hot-fix plan for the hub: `docker cp` the patched script into the running container (survives the restart policy, lost if the container is recreated), then rebuild the hub image so it is permanent; revert = `docker cp` the original back. Needs Jake's go-ahead.
(Correction: my earlier "hub is idle, 0 connections" read was the symptom of this crash loop plus cwwk01 being off, not a sign of a healthy hub.)

---
# HUB FIX APPLIED 2026-11-19 ~01:22 UTC Nov 20 (Jake: "add that fix to the hub please")
`docker cp` was refused (the hub container's rootfs is read-only). The hub's `br-supervise` is bind-mounted from the host: **`/srv/black-relay/br-supervise`** (ro in the container). My dev-tree copy was STALE (the live script has the publish/id_peers features), so the fix was made on the live file: one line, `grep -c " running " || true` in `wd_check`. Steps: verified host sha = the file I tested (6a3da41f...), backup `/srv/black-relay/br-supervise.bak-pre-grepfix` (also `~jake/br-supervise.live-orig` on the hub), patched in place, `docker restart survivability-black-relay`. Result: 0 restarts and healthy for 75+ s with cwwk01 still offline (before: restart every ~10.7 s). cwwk01 shows `active, 0 paths` (expected, it is off).
Revert: `sudo cp -a /srv/black-relay/br-supervise.bak-pre-grepfix /srv/black-relay/br-supervise && sudo docker restart survivability-black-relay`.
Source of truth fixed too (working tree only, NOT committed/pushed): `repos/black-relay-2026/survivability/identity-stack/ansible/roles/black_relay_hub/files/br-supervise` (it was byte-identical to the live pre-fix file, so a future Ansible run would have re-broken the hub). The older copies under `multipath/packaging/docker/` and `archive/` are stale/other versions: `multipath/packaging/docker/br-supervise` has my fix but is an older script (do not deploy it).
Next for Quezada: register site 2 (`sudo bash hub-add-site.sh 2`, passwordless sudo works on the hub), host DNS on cwwk02, carrier test, edge.

---
# PREPPED 2026-11-20 (night): kit built, nothing pushed, node offline

State captured first: cwwk01 as built (`as-built/cwwk01/`, snapshot 2026-11-20T23:13Z, incl. `state/`, `SPITZ.md`) and the hub (`as-built/hub/README.md`).
Everything for **Phase 1** is in `ops/cwwk/install/quezada/` (README there). **Nothing was run on cwwk02.** At prep time the node was
**unreachable**: OPNsense (tailnet node 20) last seen about 17:28 UTC on 2026-11-20 (headscale), 172.22.100.2 and .5 time out. Likely power, the nic2 cable or the lab router.

## What changed in the plan while preparing it
1. **Per-port PVIDs 100/101 on nic0/nic1 were wrong for this node.** nic2 already carries the lab trunk VLANs 101 and 102 tagged; a modem on nic1 with PVID 101 would share a
   layer-2 domain with the lab router's VLAN 101. Phase 1 does not touch nic0/nic1 at all (uplinks = tagged trunk VLANs 101 and 102). When a real modem arrives, give its port a PVID from 200 up.
2. **Phase 2 uses policy routing, not a new default gateway.** A rule "LAN/services -> any, gateway BR_EDGE" with the tailnet (100.64.0.0/10) and RFC1918 passed first. OPNsense's own traffic (its Tailscale = remote access)
   stays on the old WAN, so the cutover cannot cut remote access, and rollback is one disabled rule. (The tailnet exception matters: replies to Tailscale users would otherwise be sent into the tunnel.) Details: `quezada/OPNSENSE.md`.
3. **Phase 1 needs no host change** (not even DNS/NTP): the Debian template ships in the kit, the edge downloads packages through a temporary NIC on vmbr1 using OPNsense's resolver 172.22.100.5, then that NIC is removed.
4. **Hub registration needs a /29 transit** (edge .1, OPNsense .2, controller .3): `hub-add-site.sh` got `TRANSIT_LEN=29`. The 10.48/10.49 ranges it also registers are unused (OPNsense NATs onto the transit).
5. **Edge package:** the kit ships `black-relay-glorytun 0.3.4+br7`, byte-identical to the hub's binary. cwwk01's edge still runs br6 (works with this hub; upgrade it deliberately).
6. **Option for later (decide with Jake):** the Spitz's T-Mobile SIM gave cwwk01 real carrier diversity. On cwwk02 the Spitz is planned as an AP on nic3 (= OPNsense LAN), which forfeits that. To keep it as a carrier, nic3 would
   move to the port bridge as on cwwk01 (trunk: modem LAN + VLAN 40), and the AP's clients would need an OPNsense LAN leg on VLAN 40. Not in Phase 1.

## Built (ops/cwwk/install/quezada/)
`cwwk-addon.sh` (survey / plan / apply / status / rollback / render), `make-addon-kit.sh`, `quezada.sh` (Mac driver; changes need `QUEZADA_START=yes`), `OPNSENSE.md`, `opn-show.py` (read-only), README.
Tested without the node: shell syntax, start gate (refuses), offline path (stops cleanly), and the edge render on a real GNU userland (every cwwk01 address replaced: nft, br-edge-routes, br-watchdog, br-selftest, dash.json; the render asserts no 10.39/10.40 is left and that br-edge-routes parses). **Not tested:** `pct create` and the join on the real Proxmox.

## The start sequence (when Jake says start and the node is online)
`bash quezada.sh preflight` -> hub `sudo TRANSIT_LEN=29 bash hub-add-site.sh 2` + scp the join file -> `QUEZADA_START=yes bash quezada.sh push JOINFILE` -> `... apply` -> `bash quezada.sh status` + hub list -> (window, person on site) Phase 2.
Reminders due at the start: **RAM over-commitment** (20 GiB of VM RAM on 15.7 GiB; shrink OPNsense to about 2 GB, it uses about 1 GB), delete/replace the root-level OPNsense API key and rotate the node root password when the work is done.

---

# PHASE 1 APPLIED 2026-11-21 (02:13-02:25 UTC): the edge is in and carrying the tunnel

Jake said start. `br-edge` (CT 110, Debian 13, glorytun br7 + wstunnel 11.1.0) is running on cwwk02 and joined the hub as site 2 (idx 2, port 5002, transit 10.47.0.0/29).
**Proven:** hub lists `cwwk02` with 6 paths; ping over the tunnel to the hub works (about 234 ms: the carrier is the Spitz's T-Mobile LTE); exit address from the edge = 89.167.30.202;
the CT came back after a restart on its own in about 10 s. Nothing else changed on the node (VMs 100/101/102, bridges, host routes as before).

**Corrections to the PREPPED section above (it is partly stale):**
- The uplink is **not** the lab trunk VLANs 101/102 (items 1 and 3): Jake moved the Spitz to nic2 and those VLANs are gone. The edge's `up0` sits on the **native/untagged segment of vmbr10** (the Spitz's modem LAN,
  192.168.9.x, the same one OPNsense's WAN uses). Real modems on nic0/nic1 later need `cwwk-addon.sh ports` first (own PVID from 200 up).
- Item 6 is settled: the Spitz is the carrier on cwwk02 (one carrier for now). cwwk01 is ISP-only until its Spitz cable goes back to nic3.

**Three bugs found on the first real run (all fixed in `quezada/cwwk-addon.sh`, kit rebuilt):**
1. `umask 077` made `pct create` unpack the template into 0700 directories, which the unprivileged container's tar could not write (`tar ... failed: exit code 2`). Now `umask 022`; secrets use explicit modes.
2. `black-relay-setup join` recorded `UPLINKS="eth9:auto"` (the temporary download NIC); `br-uplinks` crashed on the name (`int('h9')`) and the tunnel restarted in a loop. The installer now writes `UPLINKS="up0:auto"` (one per uplink).
3. The HTTPS lanes could not find the hub: DNS to 1.1.1.1 rides the tunnel, which needs the lanes. cwwk01's edge has `89.167.30.202 headscale.l8s.dev` in `/etc/hosts`; the kit never wrote it. The installer now does.
(On cwwk02 these two config fixes were applied by hand in CT 110 and the installer fixed afterwards; a fresh run of the rebuilt kit does them itself, but that exact path has not been re-run on a clean node.)

**Not done: Phase 2** (OPNsense behind the edge, `quezada/OPNSENSE.md`). It needs a person on site, a `vzdump` of VM 100 first, and Jake's go. OPNsense today: WAN 192.168.9.148 via the Spitz, LAN 172.22.100.5,
OPT2 172.22.41.5, OPT1 = Tailscale 100.64.0.20; no policy routing yet. Until Phase 2 the site's users still leave through the Spitz directly, not through the tunnel.

---

# PHASE 2 APPLIED 2026-11-21 (~03:00-03:45 UTC): LAN and services now leave through the multipath tunnel

Jake: "i need the traffic and services to be presented the way that the current cwwk02 currently is, just multipath added." Addressing, DHCP, DNS (172.22.100.5), the services net (172.22.41.0/24)
and the tailnet routes are unchanged; only internet-bound traffic from LAN + services now exits via the edge -> tunnel -> hub (exit 89.167.30.202, Helsinki).
Done through the OPNsense API: `quezada/opn-phase2.py` (idempotent; tested: status, gate refusal, no-op second apply). Details and corrections: `quezada/OPNSENSE.md`.

**Backups first:** `~/Desktop/cwwk02-backups/opnsense-config-pre-multipath-20261120T213741.xml`; Proxmox snapshot `pre-multipath` on VM 100 (still there: `qm delsnapshot 100 pre-multipath` when happy).
**On cwwk02:** `qm set 100 -net3 virtio,bridge=vmbr2` (hot-added vtnet3, no restart); OPNsense: interface BR_TRANSIT (opt3, 10.47.0.2/29), gateway BR_EDGE (10.47.0.1, not default, monitored),
outbound NAT -> hybrid + 2 rules on BR_TRANSIT, static routes 1.1.1.1/32 + 1.0.0.1/32 via BR_EDGE + Unbound forwarders to them, aliases MP_SiteNets (172.22.100.0/24, 172.22.41.0/24) and
MP_LocalTailnet (RFC1918 + 100.64.0.0/10), two floating quick rules on LAN+services (exception, then "via BR_EDGE"). **Edge:** `site_open` gate now holds 10.47.0.0/29 (live + /etc/nftables.conf; the installer ships it).
**Rolled out in two stages:** canary (the Proxmox host only), then the whole LAN + services nets.
**Proven:** host exit = hub IP; DNS works (about 250 ms, through the tunnel); 20 MB download 0.7 MB/s (one stream over one LTE carrier at about 240 ms RTT); TLS sites load; tailnet -> LAN host and -> services VM
(172.22.41.10) still work during and after; OPNsense stays online in the tailnet; state table shows LAN flows NAT'd to 10.47.0.2 and no flows left on the direct WAN. IPv6: not configured on LAN/services, no leak path.
**Not proven / open:** failure behaviour when the edge or tunnel dies (reasoned in OPNSENSE.md, untested); one services state (172.22.41.10 -> 199.165.136.101:443, 3 h old) was reset so it would reconnect through the
tunnel and had not reconnected when checked (service unknown; the destination gives no TLS data to a plain client from any IP, so this is not an IP block by the hub); Spitz Wi-Fi (VLAN 40) still has no DHCP on this node
(unchanged from before: optional step in OPNSENSE.md); a LAN cable for the Mac must go in **nic3** (nic0 is a modem-side port: the Mac there sits on the Spitz network).

## Test for the teams + the multipath page (2026-11-21, after Phase 2)
- **Tailnet access (headscale live policy):** one grant gives group:survivability, group:detection, group:sensor_fusion and tag:sensor-fusion devices `ip: *` to 172.22.100.0/24 and 172.22.41.0/24; the cwwk02 OPNsense (node 20) advertises and serves both routes. Checked as Jake only (survivability); the other groups were read from the policy, not logged in as.
- **Services found:** TAK server 172.22.41.15 (8089 CoT TLS, 8443, 8444, 8446; cert CN takserver), Ubuntu 172.22.41.10 (22, 8080, 8090, MQTT 1883, RTSP 8554), Proxmox 172.22.100.2, OPNsense 172.22.100.5. Reachable over the tailnet. The services were idle at test time, so their own egress through the tunnel was not observed (same rule as the proven host canary).
- **The multipath settings page is the CONTROLLER**, which is not installed on cwwk02 (cwwk01: https://10.40.0.10 on site, https://headscale.l8s.dev/cwwk/ anywhere; cwwk02's /cwwk2/ returns 404). Planned for Phase 3: CT 111 at 10.47.0.3, with its Pocket ID redirect URI registered for /cwwk2/.
- **br-dash bug (kit):** the edge's read-only dashboard crash-looped (about 1000 restarts) because /usr/sbin/br-dash (and /usr/share/black-relay/dash/index.html) is in no package and the kit never shipped it. Installed on cwwk02 by hand (byte-identical to cwwk01's), added to the kit, and the renderer now rewrites its built-in 10.40.0.1; render re-tested on GNU. It listens on 10.47.0.1:8088 and the edge firewall lets only the controller (10.47.0.3) reach it, so nobody can open it until the controller exists.

# ISP ADDED 2026-11-21 (~03:25 UTC): second carrier, multipath proven
ISP cable in **nic1** (venue network 192.168.130.x, 1 Gbit). `MODEM_PORTS=nic1 cwwk-addon.sh ports` gave nic1 its own VLAN 200 and the edge a NIC `up1` on it (nic0 left on the native segment: the Mac's cable is there). The edge got 192.168.130.152 by DHCP and `br-uplinks` recognised it (kind isp, caps 500/300) **but only adopts a new uplink at the next tunnel start** (the recheck timer fixes labels and stale leases, it never adds ports): `pct exec 110 -- systemctl restart black-relay@br0`. Result: UPLINKS="up0:1000/1000 up1:500/300", 12 lanes, hub shows 12 paths, exit 89.167.30.202.
**Failover (22 s black-hole of one uplink's outgoing traffic, 4 pings/s through the tunnel from a LAN host):** Spitz dead: 2 of 220 lost (0.9%), longest gap 0.5 s; ISP dead: 0 of 220 lost. Both recovered by themselves. Earlier lane-kill test (2 of 6 lanes): 1.5% loss, self-healed.
**Speed:** ISP alone 27 Mbit/s one stream, 64 Mbit/s with four streams; Spitz alone about 3-6 Mbit/s; both at the current weights (Spitz 1000/1000 vs ISP 500/300) only 6.4 Mbit/s aggregate, because the Spitz gets about two thirds of the traffic and is the ceiling. The weights are Jake's policy call (ISP is the least trusted link): lowering the Spitz's cap (or raising the ISP's) moves the share; carriers.conf on the edge, then `br-uplinks apply` + tunnel restart.
**TAK TLS:** server cert CN=takserver, SAN DNS:takserver only (no IP), issued by BLACKRELAY-CWWK02-ROOT (CA, to 2036); server cert valid 2026-11-18 to 2028-11-17; copies in ~/Desktop/cwwk02-certs; client certs and keys live on the TAK VM (no login yet).

# PHASE 3 APPLIED 2026-11-21 (~04:50 UTC): the controller, "control cwwk02 like the first one"
CT 111 `br-controller` at **https://172.22.100.7** (LAN + tailnet; transit .3 = 10.47.0.3). Built by `quezada/cwwk-addon.sh controller` (kit now ships `controller/`). The controller code is the repo's `controller/app.py` plus an `OpnRouter` adapter
(OPNsense API instead of OpenWrt ubus; `router.kind = "opnsense"`), rendered for cwwk02's addresses (render test on GNU: no cwwk01 address left). Edge: `br-ctl` over a forced-command SSH key from 10.47.0.3; Proxmox: role BlackRelayController (audit + power) on a token.
**Tested (signed in over the tailnet):** Network = OPNsense (interfaces, DHCP, uptime), Compute = all 5 guests, Services = TAK (TLS), RF console (HTTP 200), MQTT, RTSP all good, Multipath = reads and can set the edge's settings, Wi-Fi = Spitz AP reachable.
**Warnings shown:** RAM 92% (real: the over-commitment), "Host helper: no answer" (no br-hostinfo on this host), Spitz lane "loss est." decaying after my 75 s blackout test (97% to 20% in 4 min; clears itself).
**Not done:** remote access for the teams (hub Caddy path + Pocket ID client for /cwwk2/); site lock; host helper. The OPNsense API key it uses is the root-level one (rotate it when the work is done). Admin password: host `/root/black-relay/controller-admin.pw`, copy `~/Desktop/cwwk02-controller-admin.txt`.
**TAK certs:** the TAK server rejected a guessed login on SSH, the HTTP API and the OAuth web login (401); no certs issued, no further guesses made.

## Single sign-on for the cwwk02 controller (2026-11-21)
- **Why SSO did not work:** (1) the LAN address https://172.22.100.7 is password-only by design (as on cwwk01: on site = admin password, remote = Pocket ID only through the hub path); (2) the hub path https://headscale.l8s.dev/cwwk2/ was not published; (3) the controller has no Pocket ID client (its page says "Pocket ID sign-in is not configured").
- **Done:** hub path published with `sudo GW=10.47.0.3 bash hub-publish-site.sh 2` (script now takes GW: the Quezada controller's listener is on the transit): Caddy route /cwwk2/ + hub forward 8445 -> 10.47.0.3:8444, Caddy validated first (backup /srv/edge/Caddyfile.bak-20261121-044850, delete when happy). https://headscale.l8s.dev/cwwk2/ answers (200) and cwwk01's /cwwk/ is unchanged (200).
- **Still needed (Jake, Pocket ID admin UI; Pocket ID has no API key here):** new OIDC client "CWWK 2 controller", callback `https://headscale.l8s.dev/cwwk2/oidc/callback`, PKCE on, not public, allowed groups survivability + headscale-users (admin = survivability, viewer = headscale-users). Then `ssh -t root@172.22.100.2 'bash /root/quezada-kit/cwwk-addon.sh controller-oidc'` (asks for the client ID and secret, secret hidden) and sign in at https://headscale.l8s.dev/cwwk2/.

## "Not allowed" on the cwwk02 portal: access list never synced (fixed 2026-11-21)
**Cause:** the controller learns who may sign in from the hub's access list (`http://10.255.N.1:8099/identity.json`). The hub serves that only to each site tunnel's own address (nft set id_peers, "a device behind a site's edge keeps its own LAN source address and is dropped"), and the controller is such a device, so its fetch timed out, it had no list at all, and even an admin was refused.
**Same on cwwk01:** its controller cannot fetch it either; its cache (`/etc/br-controller/identity-cache.json`) is from 2026-11-07, so it only works from that two-week-old copy. Not changed (production): offer the same one-rule fix there.
**Fix on cwwk02 (edge):** one source rewrite, only for the controller -> hub :8099 flow: `oifname "br0" ip saddr 10.47.0.3 ip daddr 10.255.2.1 tcp dport 8099 snat ip to 10.255.2.2` (live + /etc/nftables.conf; installer step added, generated script proven on GNU). The hub still drops every other source (LAN devices, OPNsense).
**Result:** feed answers HTTP 200 (14 people, 10 groups), "Access list sync: good", roles: 4 admin (Administrator, Jake, Marcel, Robbie), 9 viewer, 1 none.
**Services VM login:** root / the shared password is refused over SSH on 172.22.41.10 (Ubuntu normally blocks root password logins over SSH; may work on the console). Needs a normal account or PermitRootLogin enabled. TAK VM not retried.

# WI-FI WORKING 2026-11-21 (~05:50 UTC): the Spitz's Wi-Fi is on the LAN; known-good state recorded
**Cause of "wifi has no connection":** the Spitz was fine (BR_2026_2 and BR2026_5 up, bridged to VLAN 40 on the nic2 trunk, clients associating). Wi-Fi clients' DHCP requests reached cwwk02 tagged VLAN 40 and nothing there served that VLAN (OPNsense has no VLAN-40 network), so nobody answered. Nothing needed "nuking": no Spitz change, no OPNsense change.
**Fix:** `cwwk-addon.sh wifi` = a veth patch (`wifi40a` on vmbr10, VLAN 40 untagged; `wifi40b` on vmbr1, the LAN) so Wi-Fi clients are ordinary LAN devices served by OPNsense's DHCP/DNS (172.22.100.x, gateway/DNS .5, the same rules, the tunnel, the tailnet). VLAN 40 is then removed from nic0/nic1 (the outside-facing ports, incl. the ISP port; it is the LAN now). Persistent: `br-wifi-patch.service`. Undo: `cwwk-addon.sh wifi-rollback`.
**Proved:** synthetic client on VLAN 40 got 172.22.100.124, reached OPNsense, the internet (exit 89.167.30.202) and the TAK server; a real client (a Mac, MAC 1a:4a:71:93:ca:33) associated on 2.4 GHz and got 172.22.100.187; its flows: 99 through the edge, 0 on the direct WAN.
**Cautions:** the Spitz LAN port (eth1) is on the same VLAN 40 = the LAN: a switch there joins the LAN; never cable it to cwwk02's nic3 (no STP on that side = loop). `ifreload -a` re-adds VLAN 40 to nic0/nic1: re-run `systemctl restart br-wifi-patch`. Wi-Fi speed is the carriers' (about 6 Mbit/s today with the weights as they are).
**Known-good marker:** OPNsense config `~/Desktop/cwwk02-backups/opnsense-config-KNOWN-GOOD-wifi-*.xml`; everything else (edge, controller, SSO, ISP, Wi-Fi) is reproducible from the kit (`~/Desktop/quezada-kit.tar`, 44 files) with the commands in quezada/README.md.
