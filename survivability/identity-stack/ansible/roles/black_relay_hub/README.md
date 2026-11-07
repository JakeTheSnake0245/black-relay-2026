# black_relay_hub: Black Relay "Multithread" hub on BR2026

Runs the Multithread hub container and publishes chosen field-site services to the edge Caddy.
Wired into `playbooks/site.yml` after `identity_stack` (tag `black_relay`). Matches what runs on
BR2026 as of 2026-11-07.

## What it manages

| item | where | note |
|---|---|---|
| Hub container | `/srv/black-relay/` (`compose.yml`, `ws.env`, `br-supervise`) | No published ports. Joins `edge_proxy_network` as 172.29.0.10, alias `multithread`. Sites reach it over WSS through Caddy. |
| Published site services | `/srv/black-relay/etc/publish.conf` from `black_relay_hub_publish` | `br-supervise publish`: DNAT `multithread:<port>` to the site address, SNAT to the tunnel address so replies return through the tunnel. TCP only, exact address:port, only to the hub's proxy address (`BR_PUBLISH_ADDR`), never from a tunnel. |
| Socket buffers | `/etc/sysctl.d/90-black-relay.conf` | Host-wide (not namespaced on this kernel). |
| Identity snapshot | `/usr/local/sbin/br-identity-export` + `br-identity-export.timer` | Secret-free people/groups/policy snapshot that sites fetch through their tunnels, so access rules keep working offline. `:8099` answers only each tunnel's peer address (`PEER=` in the site config) on that tunnel's own device. |
| Hub image | `black_relay_hub_image_ids` | The image under the tag must have one of these IDs (config digest for the classic image store, manifest digest for the containerd store), or the role fails. Set the list empty to skip the check; after a new build, take the value from `docker image inspect --format '{{.Id}}' <tag>`. |

Edge routes for the hub live in `roles/edge/templates/Caddyfile.j2`, inside the Headscale site:
`/multithread-*` → `multithread:8080` (site lanes) and `/cwwk/*` → `https://multithread:8444` (the
CWWK site controller, which requires a Pocket ID sign-in; Caddy pins the controller's own
self-signed certificate). Without these, the edge role's next converge would remove them and take
the sites down.

## Not managed here

- Site keys and configs and `black-relay.env` tuning in `/srv/black-relay/etc` (`black-relay-hub add <site>`).
- LLDAP read-only user `br-identity-export` (group `lldap_strict_readonly`); its credentials are in
  `/etc/black-relay-identity/export.env` (0600), created by hand.
- The Pocket ID OIDC client for the CWWK controller (callback `https://<headscale_domain>/cwwk/oidc/callback`).

## Before the first converge

- Add `black_relay_hub_ws_prefix` (`multithread-<32 hex>`) to `secrets.sops.yml`. The live value is
  `BR_WS_PREFIX` in `/srv/black-relay/ws.env`. The role refuses to run without it.
- Put `black-relay-image_0.3.5-mt3_amd64.tar.gz` in `files/` (git-ignored) only if the image is
  not already loaded on the host. The checksum is verified before `docker load`.
- **Expect one hub restart.** The committed `compose.yml` and `br-supervise` differ from the
  hand-installed ones, so "Hub running" recreates the container once (never twice: a changed
  `br-supervise` or `ws.env` adds `--force-recreate` to the single `up -d`). Every site tunnel
  drops for ~40 s, including a site's own Tailscale, which rides it. Run it in a quiet window,
  or converge `--tags edge` first and the hub later.

## Gotcha

`br-supervise` is bind-mounted as a single file. Replacing it on the host gives it a new inode,
so the running container keeps the old copy until it is recreated ("Hub running" does
this when the file changed). Never `docker exec … br-supervise <cmd>` against a container that predates the command:
older copies treated any argument as the entrypoint and started a second supervisor. The publish
handler checks for support first.

## Known limits

- **Sites are not isolated from each other at the WSS layer.** All sites share one secret
  upgrade prefix, and the wstunnel server's `--restrict-to` list covers every site's UDP port,
  so a compromised site (which holds the prefix) can open lanes to other sites' ports. Their
  glorytun keys still protect the tunnels themselves. The fix is a per-site prefix with
  `wstunnel server --restrict-config`, mapping each prefix to that site's port only.
- The identity snapshot is limited to each tunnel's peer address. A site that masquerades
  its LAN into the tunnel lets every device behind it fetch the snapshot; keep that NAT off
  at the site, or filter `:8099` there.
- Published site services are pinned to the hub's proxy address but not to a source: Caddy
  has no fixed address on the proxy network, so any container on it can reach them. The site
  service's own sign-in is the gate.
- The Caddy access log redacts the secret prefix from `request>uri`. Caddy's own error log
  (`docker logs`) can still print the URI of a failed proxied request.
