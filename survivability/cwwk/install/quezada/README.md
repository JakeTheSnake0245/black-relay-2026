# The Quezada build (cwwk02): Black Relay multipath in front of OPNsense

Plan and findings: `ops/cwwk/docs/cwwk02-opnsense-plan.md`. Current cwwk01 as built: `ops/cwwk/as-built/cwwk01/`.

**Phase 1** (this kit) adds ONE container, `br-edge` (CT 110), to the running node. It uses the existing
VLAN-aware port bridge `vmbr10` (uplinks = tagged VLANs of the lab trunk on nic2) and the empty `vmbr2` (transit
10.47.0.0/29). Nothing that exists is changed: OPNsense, VMs 100-102, the bridges, ports, routes, DNS, SSH. Undo:
`cwwk-addon.sh rollback`. **Phase 2** (`OPNSENSE.md`) moves OPNsense's client traffic behind the edge, supervised.

## Before "start" (nothing here changes the node)
```
bash quezada.sh plan            # exactly what apply will do
bash quezada.sh kit             # builds ~/Desktop/quezada-kit.tar (SHA256SUMS inside)
bash quezada.sh preflight       # read-only survey of the node (needs the node online)
python3 opn-show.py             # read-only look at OPNsense (needs the node online)
# node login: export SSHPASS=...   (one shell, never saved) unless the Mac key is installed on the node
```

## Start (Jake says go; node online)
1. **Hub** (BR2026): `ssh jake@100.64.0.5 'sudo TRANSIT_LEN=29 bash hub-add-site.sh 2'` then
   `scp jake@100.64.0.5:cwwk02.join ~/Desktop/` (the join file is a secret; delete it at the hub after the install).
2. **Push and apply** (Mac): `export SSHPASS=...` (or key login), then
   `QUEZADA_START=yes bash quezada.sh push ~/Desktop/cwwk02.join`, `QUEZADA_START=yes bash quezada.sh apply`.
3. **Prove Phase 1**: `bash quezada.sh status` (tunnel up, hub ping, exit address 89.167.30.202) and on BR2026
   `sudo docker exec survivability-black-relay black-relay-hub list` shows `cwwk02 ... active N paths`.
4. Phase 2 per `OPNSENSE.md` with a person on site.

## Honest limits
- **Today the node has ONE carrier:** nic2 goes to the Spitz (moved from cwwk01 on 2026-11-20: MAC 94:83:c4:f0:70:fe, modem LAN
  192.168.9.0/24, T-Mobile). Phase 1 gives the edge a second lease on that same segment, so the tunnel runs its HTTPS lanes over
  that one cellular carrier: it proves the tunnel and the cutover on this node, **not carrier diversity**. A second carrier = a
  modem in nic0/nic1 plus `cwwk-addon.sh ports` (own VLAN per port, so it does not share the Spitz's segment).
- The Spitz's Wi-Fi (VLAN 40) has no DHCP on this node yet: see "Wi-Fi onto the LAN" in `OPNSENSE.md`.
- Remote access to the node rides OPNsense's Tailscale. Phase 1 never touches it; Phase 2 keeps OPNsense's own traffic
  on its WAN on purpose.
- The edge is 1 GiB RAM-limited (about 300 MiB in use) on a host whose VMs already over-commit RAM (20 GiB on 15.7 GiB).
- Not in this kit yet: controller (CT 111), site lock, host DNS/NTP fix, services.
- Tested without the node: shell syntax, the edge file render on GNU userland, dry-run plan. Not tested: `pct create`
  and the join on the real Proxmox (the survey/apply gates exist because of that).

## Phase 2 (applied 2026-11-21): `opn-phase2.py`
`python3 opn-phase2.py status` (read-only) shows what is configured. `QUEZADA_START=yes python3 opn-phase2.py apply [HOST-or-NET ...]` creates BR_TRANSIT, the BR_EDGE gateway,
hybrid outbound NAT, DNS via the edge and the two floating policy rules; run it twice and the second run changes nothing. First time on a new site: `apply 172.22.100.2` (one canary host), prove it, then
`sources 172.22.100.0/24 172.22.41.0/24`. `off` / `on` switch the policy rules (rollback). Needs the transit NIC (`qm set 100 -net3 virtio,bridge=vmbr2` on the Proxmox host) and Phase 1. Details: OPNSENSE.md.

## Phase 3 (applied 2026-11-21): the controller, `cwwk-addon.sh controller`
The same web UI as cwwk01 (health, multipath sliders, network, compute, services, setup), as CT 111 `br-controller`: LAN address https://172.22.100.7 (site LAN + tailnet), transit address 10.47.0.3
(drives the edge through its forced-command key `br-ctl`, answers the hub's remote-access path). It reads OPNsense through the API (`router.kind = opnsense`, an adapter in `controller/app.py`), Proxmox through a read+power
API token (`br-controller@pve!ui`), and has no lock agent or host-info helper (those two show as "not installed"/"no answer"). Needs `/root/.opn-api` (key=/secret=) on the host for the run; the installer removes it.
The break-glass admin password is written to `/root/black-relay/controller-admin.pw` on the host. Remote access for the teams (Pocket ID at `https://headscale.l8s.dev/cwwk2/`) needs the hub path and a Pocket ID client: not done.
`bash cwwk-addon.sh controller-rollback` removes CT 111, the Proxmox token and the controller's key on the edge.
