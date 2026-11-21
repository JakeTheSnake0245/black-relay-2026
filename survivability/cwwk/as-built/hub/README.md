# BR2026 hub, as of 2026-11-20 (read-only capture; no secrets)

Host `blackrelay-vps` (Hetzner, 89.167.30.202, tailnet 100.64.0.5). Containers: `survivability-black-relay` (image `black-relay:0.3.5-mt3`, glorytun br7, md5 e6be9ee6...,
identical to `multipath/dist/black-relay-glorytun_0.3.4+br7_amd64.deb`), headscale v0.29.3, caddy 2.11.4, pocket-id v2.14.0, lldap v0.6.3, sf-dev.

Registered sites (`black-relay-hub list`):
```
SITE           IDX   PORT  SITE-ADDR       STATE     PATHS
cwwk01           1   5001  10.255.1.2      active    12
```
cwwk02 is NOT registered yet (first step of the Quezada start: `sudo TRANSIT_LEN=29 bash hub-add-site.sh 2`).

Fix in place since 2026-11-20 01:22 UTC: `/srv/black-relay/br-supervise` (bind-mounted read-only into the container) counts running paths with
`grep -c ... || true`, so a registered site with 0 paths no longer crash-loops the hub tunnel service for every site. Source copy:
`repos/black-relay-2026/.../identity-stack/ansible/roles/black_relay_hub/files/br-supervise` (working tree, uncommitted). Backups next to the live file.
Headscale policy (live `/srv/identity-stack/headscale-config/policy.hujson`, applied with `~jake/br2026-apply-policy.sh`) includes cwwk-01 and cwwk-02
LAN grants for every team; the repo copy `headscale-policy.hujson` is synced to it (uncommitted).
Hub does NOT accept tailnet routes (keep it off: hub->site traffic must stay inside the tunnel).
