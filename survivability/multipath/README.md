# Black Relay Multipath ("Multithread")

Bonds every available internet connection at a field site (ISP, Starlink, cellular) into one
encrypted tunnel to the BR2026 hub, so the site keeps working when any single connection drops,
and nothing ever leaves the site unencrypted.

```
modems ──► site edge (br-edge) ──► 6 TLS lanes per modem ──► BR2026 Caddy :443 ──► hub ──► internet
 (any port)   recognises each modem                           (/multithread-*)           89.167.30.202
```

This folder is the multipath system itself. Running the CWWK site box and the BR2026 server
day to day: the CWWK site box is `../cwwk/`, BR2026 itself is `../identity-stack/`.

## Layout

| path | what |
|---|---|
| `glorytun-fork/` | Patches to glorytun (multipath UDP tunnel): bonding/resequencing, path table, fixed MTU for WebSocket lanes, FEC, security fixes. |
| `packaging/` | Builds the `black-relay` .deb / OpenWrt .ipk / hub container image (`build.sh` → `dist/`). `files/` holds the tunnel helper, watcher, live dashboard (`br-dash`) and hub tools. |
| `edge/` | Site-edge tools (installed on a site's `br-edge` container): `br-uplinks` (recognises the modem in each port, re-checks every minute), `carriers.conf` (modem kinds and speed caps), `br-ctl` (the controller's only commands), `br-selftest`, `br-lane-nurse`, firewall (`nftables.conf`), networkd files. |
| `dist/` | Built packages and hub images, with `SHA256SUMS`. |
| `docs/` | `diagrams.md` (Mermaid; rendered to `../docs/Black-Relay-Diagrams.pdf` by `scripts/render-diagrams.py`), `lab-results.md` (measurements behind the defaults). |
| `gt-lab/`, `analysis/` | Three-lane netns lab and capture-analysis tools; live checks at both ends (lane randomness, known-stream wire search): report in `docs/live-randomness.md`. |
| `scripts/deploy-test.sh` | Push the fork + lab to a throwaway VPS and run the self-tests (never production). |

The hub side on BR2026 is Ansible: `survivability/identity-stack/ansible/roles/black_relay_hub`
and the edge Caddyfile in the black-relay-2026 repo (`../identity-stack/`).

## How it works

- **Lanes:** each modem carries 6 WebSocket/TLS lanes to `wss://headscale.l8s.dev` (only 443 is
  open on BR2026). glorytun spreads packets across all lanes, weighted by each modem's caps,
  and the hub puts them back in order and sends them on from Hetzner.
- **Any modem, any port:** `br-uplinks` recognises the modem by a probe only it answers (the
  Starlink dish), its address range, or its gateway (Spitz 192.168.9.1); anything else is "ISP".
  Caps and colors follow the modem, not the port.
- **Fail closed:** the edge firewall lets nothing out of a modem except the lanes, DHCP and
  modem admin pages from the site LAN. If every lane is down, traffic stops; it never leaks.
- **MTU:** WebSocket lanes run at a fixed 1400 (fork patch 0003; glorytun's own probe can't
  see through TLS).

## Building

`packaging/build.sh` (needs Docker): fetches glorytun at the pinned commit, applies the patches,
builds static binaries for x86_64 and aarch64, packages them into `dist/`. Version in the script
(`PKG_VERSION`, currently `0.3.4+br6`).
