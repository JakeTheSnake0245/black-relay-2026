# Quick install: another CWWK site box

Turns a fresh CWWK running Proxmox VE 9 into site N: the same build as cwwk01 (multipath
edge, OpenWrt router, controller, port roles, port lock, site lock). Both sites stay on
the BR2026 hub at the same time, each with its own tunnel and addresses.

| site | name | transit | LAN (Wi-Fi, laptops) | services | controller |
|---|---|---|---|---|---|
| 1 | cwwk01 | 10.39.0.0/30 | 10.40.0.0/24 | 10.41.0.0/24 | https://10.40.0.10 · headscale.l8s.dev/cwwk/ |
| 2 | cwwk02 | 10.47.0.0/30 | 10.48.0.0/24 | 10.49.0.0/24 | https://10.48.0.10 · headscale.l8s.dev/cwwk2/ |
| N | cwwk0N | 10.(39+8(N−1)).0.0/30 | 10.(40+8(N−1)).0.0/24 | 10.(41+8(N−1)).0.0/24 | https://10.(40+8(N−1)).0.10 |

On every site: router `.1`, Proxmox host `.2`, controller `.10`, DHCP `.100`–`.199`.

## Fast path (one command from the Mac)

```
bash new-site.sh                      # asks for the site number and the box's address
```

(or `bash new-site.sh 2 <address>`; your SSH key is copied to the box for you.) It registers the site on BR2026 (one sudo password prompt), builds the kit, copies it over and
runs the preflight and install on the new box. Then, **at the new box's console**:

```
cd /root/cwwk-kit && bash cwwk-bootstrap.sh 2
```

That moves the ports, waits while you plug in the modems and the Spitz, brings up the tunnel and
the tailnet, turns host SSH passwords off and finishes with the proof (`br-verify`). It remembers
where it is: if the network move drops your session, log in again and run the same command.
What only a person can do (USB stick for the site lock, Spitz Wi-Fi, Pocket ID client, port lock)
is printed at the end and shows as a WARN in the proof until done. The numbered steps below are
the same thing by hand.

## Services (Sensor Fusion containers from sf-dev)

The site runs the services that are developed on sf-dev in CT 104 `br-services` (Docker, on the
services network at `10.(41+8(N-1)).0.20`, behind the site lock). The install creates it
(`br-svc init`); a **bundle** brings a service: project files + the built images + a version
hash, so the site needs no registry and no internet. Passwords are made per site on first deploy
and never leave it (`br-svc creds NAME` shows them on request). What to ship is in
`../services/services.json`.

```
bash svc-sync.sh sync root@<site>     # sf-dev -> your Mac -> site; deploys and checks health
bash svc-sync.sh status               # drift: sf-dev version vs every site (OK / OUTDATED / NOT DEPLOYED)
```

`new-site.sh` packs the current services into the kit, and the bootstrap starts them. On the box:
`br-svc status | deploy FILE.tar | creds NAME | logs NAME | remove NAME`. A redeploy keeps the
site's passwords and data volumes. A service appears as a tile in the controller automatically.
Add another service: one entry in `services.json` (its card, compose files, profiles), build its
images on sf-dev, `svc-sync.sh sync`.

## Is it installed and up? `br-status`

One screen, any time, on the box (or `bash cwwk-bootstrap.sh --status`): installed or not, and
UP / DOWN per area (host, ports, tunnel, router, controller, services, hub, security), the
controller and services addresses, and only the problems spelled out.

## The proof: `br-verify`

Run it any time, on any site (`br-verify`, `br-verify --strict`, `br-verify --quiet`, `--section edge`).
Read-only, about 20 seconds, ~100 checks: Proxmox and containers, bridges and every port on the
port bridge, tunnel and lanes, the leak guard, internet exit = the hub (not a local carrier),
router (firewall, DHCP, DNS, addresses), services host and every deployed service healthy, controller (credentials, certificate, can drive the edge,
reaches the Proxmox/site-lock/router), tailnet, SSH hardening, secret file permissions, site lock
and port lock. It exits 1 on any FAIL. **READY** = all ok; **READY WITH NOTES** = only "not done
yet" items; **NOT READY** = something is broken.

## What you need

- The new CWWK with **Proxmox VE 9** installed (any hostname, `local-lvm` storage), its
  management port on a network with internet, and your SSH key on it:
  `ssh-copy-id root@<install address>`.
- cwwk01 online (the kit is copied from it) and BR2026 reachable.
- The modems for the new site, the Spitz, a USB stick for the site lock.

## Steps

Mac commands run from this folder (`install/` in the CWWK folder).

**1. Mac: build the kit** (about 150 MB; reads cwwk01, changes nothing there)

```
bash make-kit.sh
```

**2. BR2026: register the site** (site 2 shown)

```
scp hub-add-site.sh jake@100.64.0.5:
ssh -t jake@100.64.0.5 'sudo bash hub-add-site.sh 2'
scp jake@100.64.0.5:cwwk02.join ~/Desktop/
ssh jake@100.64.0.5 'shred -u cwwk02.join'
```

The join file is secret (tunnel key, lane prefix, a one-hour tailnet key). The installer
keeps it root-only on the new box and wipes the tailnet key once used. If the hour passes
before `finish`, make a new key the same way (`hub-add-site.sh 2` again reuses the site).

**3. New CWWK: install** (nothing is cabled yet; the install network keeps working)

```
scp ~/Desktop/cwwk-kit.tar ~/Desktop/cwwk02.join root@<install address>:
ssh root@<install address>
tar xf cwwk-kit.tar && cd cwwk-kit
bash cwwk-install.sh plan 2
bash cwwk-install.sh install 2 /root/cwwk02.join
```

About 5 minutes. It creates br-edge (101), br-router (102) and br-controller (103) with
the site's addresses, joins the hub, makes new keys and passwords for this box only
(`/root/black-relay/`), and installs the host tools (port roles, port lock, site lock,
host info). cwwk01's passwords, keys and certificates are never copied.

**4. Ports** (from the CWWK console, or keep the SSH session: it drops here)

```
bash cwwk-install.sh ports
```

Every port joins the port bridge, so any cable works in any port, and the install network
ends. It undoes itself after 15 minutes unless step 5 runs. Then plug in the modems, the
Spitz (step 7 first if it's new) and a laptop in a free port. After about a minute the
laptop gets a `10.48.0.x` address; `ssh root@10.48.0.2`.

**5. Finish**

```
bash /root/cwwk-kit/cwwk-install.sh finish
```

Waits for the tunnel, keeps the port layout, joins the tailnet (`cwwk-node02`), turns host
SSH passwords off, and runs the self-test. Controller: https://10.48.0.10, admin password in
`/root/black-relay/controller-admin.pw`.

**6. Site lock** (USB stick in the CWWK; shows the vault passphrase once, so write it down)

```
br-vault-init
```

From the next power-on the box starts locked, like cwwk01: USB key, or admin + passphrase.

**7. Spitz** (if it's not set up yet: laptop cabled to the Spitz, before it goes into the CWWK)

```
scp -O spitz-setup.sh root@192.168.9.1:/tmp/
ssh -t root@192.168.9.1 sh /tmp/spitz-setup.sh
```

Wi-Fi BR2026_2 / BR2026_5 on the site LAN. To give site 2 its own names:
`sh /tmp/spitz-setup.sh SITE2_2 SITE2_5`.

**8. Remote access** (once the tunnel is up)

```
scp hub-publish-site.sh jake@100.64.0.5:
ssh -t jake@100.64.0.5 'sudo bash hub-publish-site.sh 2'
```

Then in Pocket ID add an OIDC client "CWWK 2 controller" with callback
`https://headscale.l8s.dev/cwwk2/oidc/callback` (PKCE on, groups survivability and
headscale-users), and on the new CWWK host run `br-controller-oidc`.

**9. Prove it:** `br-verify --strict` must say READY (no notes) once steps 6-8 are done, then
controller **Setup → Lock the ports**, then a cold start (`survivability/cwwk/docs/cold-start-test.md`).

## Check or redo

- `br-verify` (or `bash cwwk-install.sh check`): the full proof described above.
- The install refuses a box that already has containers 101–103. To start over:
  `for i in 101 102 103; do pct stop $i; pct destroy $i --purge; done` (and `br-port-layout rollback` if the ports were moved).
- Undo the port move by hand: `br-port-layout rollback`.

## Known limits

- Tested in parts against cwwk01 (address rewrite, router export, kit build, `br-verify` on the
  live box, incl. a real services deploy: 98 ok). The whole run needs the second box.
- A box with a different number of ports works (one modem port per network port); one with
  fewer than 2 ports is refused.
- Hub ports allow up to 10 sites; the address plan goes to site 9 within 10.32.0.0/11.
