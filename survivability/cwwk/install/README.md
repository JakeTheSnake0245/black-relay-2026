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

**9. Prove it:** controller **Setup → Run self-test**, then **Setup → Lock the ports**, then a
cold start (`survivability/cwwk/docs/cold-start-test.md`).

## Check or redo

- `bash cwwk-install.sh check`: containers, host services, tunnel, lanes, site lock, self-test.
- The install refuses a box that already has containers 101–103. To start over:
  `for i in 101 102 103; do pct stop $i; pct destroy $i --purge; done` (and `br-port-layout rollback` if the ports were moved).
- Undo the port move by hand: `br-port-layout rollback`.

## Known limits

- Tested in parts against cwwk01 (address rewrite, router export, kit build). The whole
  run needs the second box.
- A box with a different number of ports works (one modem port per network port); one with
  fewer than 2 ports is refused.
- Hub ports allow up to 10 sites; the address plan goes to site 9 within 10.32.0.0/11.
