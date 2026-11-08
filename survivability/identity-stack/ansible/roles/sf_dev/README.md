# sf_dev

The Sensor Fusion box: where the TAK and Detection teams build and run their
containers, and where the fusion services (message bus, TAK server, bridges) live.

- **A Sysbox system container.** It boots systemd and runs its own Docker and
  `docker compose`, like a small VM, without `--privileged`: Sysbox gives it its
  own user namespace, so root inside is not root on this host. (The host has no
  KVM, so a real VM is not possible here.) Sysbox is installed from a pinned,
  checksummed release; the role pre-sets the Docker network settings Sysbox wants
  to today's values so installing it never restarts Docker.
- **Everything stays.** The whole system (`/usr` with `/bin` and `/lib`, `/etc`,
  `/var`, `/opt`, `/root`, `/srv`), Docker's data (`/var/lib/docker`), `/home` and
  the Tailscale identity live on its own disk (`/srv/sf-dev/disk.img`, ext4,
  loop-mounted, 80 GB, grown online if the size is raised). Restarts, recreates
  and image rebuilds keep everything. The image only seeds a new box; raising
  `sf_dev_system_generation` re-seeds the system (home, Docker data and identity
  stay).
- **Reached only over the tailnet.** Joins as `sf-dev` with `tag:sensor-fusion`
  (the Sensor Fusion mesh: every member's devices, Pis and phones reach it on any
  port) and `tag:sf-dev` (its ssh rule). `ssh dev@sf-dev` with the person's
  Pocket ID identity; one shared `dev` account with sudo and Docker inside.
- **For the teams:** a shared Docker network `fusion` (containers reach each other
  by name), `/srv/sensor-fusion/` for the teams' services, `PORTS.md` to claim
  ports, and a guide in `~/README` (all from `sf-dev-setup`, every boot). Nothing
  is published to the internet.
- **Isolation:** own Docker network `sf_dev` (172.30.0.0/24); `sf-dev-guard.service`
  drops traffic to the cloud metadata service and 10.0.0.0/8. 2 CPUs, 4 GB RAM.
- **Backup:** nightly restic takes `/srv/sf-dev/disk` as files, including Docker
  volumes, without the raw image, Docker's image layers or caches.
- **Join key:** only when the node has never joined, a single-use one-hour key
  with the sf-dev tags is written to the box's `/etc/sf-dev/ts-authkey` and
  emptied after the join. Never logged.

Policy entries it depends on (in `identity_stack/files/headscale-policy.hujson`):
`tag:sensor-fusion` and `tag:sf-dev` in `tagOwners`, the sf-dev TCP 22 grant and
the `dev` ssh rule. The role refuses to run if the tags are missing.

Remove the node: `headscale nodes delete`, delete `/srv/sf-dev/disk/tailscale/*`,
converge: a fresh key is issued.
