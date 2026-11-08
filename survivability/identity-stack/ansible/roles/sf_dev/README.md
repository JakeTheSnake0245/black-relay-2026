# sf_dev

Ubuntu 24.04 development container for the Sensor Fusion team (TAK + Detection).

- **Reached only over the tailnet.** The container runs Tailscale itself and joins as `sf-dev`
  with `tag:sensor-fusion` (Sensor Fusion mesh) and `tag:sf-dev` (scopes its ssh rule). No ports
  are published on the host.
- **Sign-in:** `ssh dev@sf-dev` from any device on the tailnet. Tailscale SSH checks the
  person's Pocket ID identity; `group:sensor_fusion` and `group:survivability` may log in as the
  shared `dev` account (passwordless sudo inside the container only). No keys or passwords.
- **Disk:** a 20 GB ext4 image (`/srv/sf-dev/disk.img`, loop-mounted at `/srv/sf-dev/disk`,
  in `/etc/fstab`) holds the **whole system**: `/usr` (with `/bin`, `/lib`), `/etc`, `/var`, `/opt`,
  `/root`, `/srv` under `disk/system/`, plus `/home` and the Tailscale node identity. It is a
  container, not a VM (the host has no KVM), but it keeps everything like one: apt packages,
  config and files survive restarts, recreates and image rebuilds. The image only seeds a new
  box (copied onto the disk once, marker `disk/system/.seeded`); update a running box with
  apt inside. No systemd: long-running programs go in tmux.
- **Backup:** the nightly restic run takes `/srv/sf-dev/disk` (files, caches excluded), not the
  raw image.
- **Isolation:** own Docker network `sf_dev` (172.30.0.0/24), off the identity networks;
  `sf-dev-guard.service` drops traffic to the cloud metadata service and 10.0.0.0/8.
  2 CPUs, 2 GB RAM, 2048 processes.
- **Join key:** only when the node has never joined (no state file), the role creates a
  single-use, one-hour key with the sf-dev tags, hands it to the container through
  `/srv/sf-dev/authkey`, and empties that file once the node is up. Never logged.

Policy entries it depends on (in `identity_stack/files/headscale-policy.hujson`):
`tag:sensor-fusion` and `tag:sf-dev` in `tagOwners`, the sf-dev TCP 22 grant, and the
`dev` ssh rule. The role refuses to run if the tags are missing.

A new image (`sf_dev_image`, e.g. `sf-dev:2`) only seeds new boxes; a running box keeps its
system. Converging with `--tags sf_dev` may recreate the container; nothing on it is lost.
Remove the node: `headscale nodes delete`, then delete `/srv/sf-dev/disk/tailscale/*` before
converging, and a fresh key is issued.
