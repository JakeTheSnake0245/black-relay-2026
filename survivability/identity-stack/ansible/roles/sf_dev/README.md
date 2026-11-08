# sf_dev

Ubuntu 24.04 development container for the Sensor Fusion team (TAK + Detection).

- **Reached only over the tailnet.** The container runs Tailscale itself and joins as `sf-dev`
  with `tag:sensor-fusion` (Sensor Fusion mesh) and `tag:sf-dev` (scopes its ssh rule). No ports
  are published on the host.
- **Sign-in:** `ssh dev@sf-dev` from any device on the tailnet. Tailscale SSH checks the
  person's Pocket ID identity; `group:sensor_fusion` and `group:survivability` may log in as the
  shared `dev` account (passwordless sudo inside the container only). No keys or passwords.
- **Disk:** a 20 GB ext4 image (`/srv/sf-dev/disk.img`, loop-mounted at `/srv/sf-dev/disk`,
  in `/etc/fstab`) holds `/home` and the Tailscale node identity. Packages installed inside the
  container are lost on a rebuild; work belongs under `~`.
- **Isolation:** own Docker network `sf_dev` (172.30.0.0/24), off the identity networks;
  `sf-dev-guard.service` drops traffic to the cloud metadata service and 10.0.0.0/8.
  2 CPUs, 2 GB RAM, 2048 processes.
- **Join key:** only when the node has never joined (no state file), the role creates a
  single-use, one-hour key with the sf-dev tags, hands it to the container through
  `/srv/sf-dev/authkey`, and empties that file once the node is up. Never logged.

Policy entries it depends on (in `identity_stack/files/headscale-policy.hujson`):
`tag:sensor-fusion` and `tag:sf-dev` in `tagOwners`, the sf-dev TCP 22 grant, and the
`dev` ssh rule. The role refuses to run if the tags are missing.

Rebuild with newer packages: bump `sf_dev_image` (e.g. `sf-dev:2`) and converge with
`--tags sf_dev`. The container restarts once; `/home` and the node identity are kept.
Remove the node: `headscale nodes delete`, then delete `/srv/sf-dev/disk/tailscale/*` before
converging, and a fresh key is issued.
