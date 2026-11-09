# Throughput without a security trade (cwwk01 + lab, 2026-11-08 night)

Goal: more throughput with **zero** security compromise: same encryption, same random
per-packet mixing, every carrier keeps exactly the share of traffic its sliders give it
(cap ÷ sum of connected caps), leak guard and HTTPS-443-only transport unchanged.

## Why it is slow

With the shares fixed, the tunnel can never be faster than

    slowest link's real capacity ÷ that link's share

Sliders tonight: Starlink 1000/1000, ISP 500/300, Spitz 1000/1000 → download shares
Starlink 43.5 %, Spitz 43.5 %, ISP 13 %. The Spitz carries ~3–7 Mbit where it sits (its
round trip climbs from ~170 ms to 350–440 ms when full), so the whole site tops out at
roughly 7–16 Mbit download, whatever the software does. Every extra Mbit the Spitz can
carry gives the site ~2.3 Mbit.

Measured live (4 parallel downloads, 20 s, Hetzner hel1 through the tunnel): sliders as set
gave 4.6 Mbit in the afternoon (70 % of delivered bytes were resends: the Spitz queue pushed
its packets past the reorder hold) and 12.5–19.9 Mbit at night (resends 4–6 %).

## What was tested (all zero-compromise)

Lab: `analysis/experiments/brlab.sh`, the production stack in network namespaces (glorytun
br6/br7, 6 wstunnel TLS lanes per uplink, random scheduler, 400 ms hold), carriers modelled
as Starlink 80/10 Mbit 110 ms 1 % loss, Spitz 8/3 Mbit 160 ms deep buffer, ISP 274/125.
Three repeats each, download Mbit (4 flows / 1 flow):

| change | result |
|---|---|
| sliders as set | 11.4–12.6 / 7.5–9.9 |
| total rate scaled, shares kept (static) | 8.0–11.9 / 6.8–10.5 |
| `br-pace` (automatic total, shares kept, baseline probing) | 10.3–12.1 / 7.3–12.0 |
| BBR on the hub's HTTPS side | 11.2–12.8 / 8.4–10.8 |
| 12 lanes per uplink (3 lanes: worse, 5.8) | 11.2–13.0 / 7.5–12.2 |
| keepalive 1000 ms, tunnel MTU 1500, hold 700 ms | 11.5–12.4 / 8.7–10.6 |

All within noise of each other: the Spitz's share of its capacity is the limit.
Live A/B of `br-pace` against the sliders (3 + 2 rounds) was not better (e.g. 9.2 vs 15.0,
8.7 vs 19.9). Not deployed; kept in `analysis/experiments/`.

## What was found instead: the hourly break

Every 60 min after the hub's tunnel process starts, the hub rotates its session key and the
data plane stops: the site switches to the new key, the hub never re-derived it, nothing
decrypts until the watchdog restarts the hub's tunnel (~30–40 s, every connection drops).
Hub log: 20:47, 21:48, 22:48, 23:49, 00:49, 01:50, 02:50, 03:51 UTC.

Fix: glorytun-fork patch 0004 (`0.3.4+br7`): the rotating end re-derives its next key from
the new secret and the peer's public key, and keeps sending under the current key until the
peer is on the new one (at most 2 s). Rotation stays hourly. Lab with rotation every 30 s:

| | hub rotates | site rotates | both rotate |
|---|---|---|---|
| br6 | 15 % of pings answered (dead after the first rotation) | 100 % | – |
| br7 | 100 % | 100 % | 100 % |

## What raises the ceiling without touching security

1. **Deploy br7 on the hub** (`ops/br2026/scripts/br2026-hub-glorytun.sh`): no more hourly
   30–40 s outage.
2. **More capacity on the trusted links, or more trusted links.** Better Spitz signal
   (placement, 5G mode, antennas) and a clearer Starlink sky raise the limit directly. A
   further trusted link at slider 1000 (a tethered phone or a second cellular modem on another
   carrier joins by itself) lowers every carrier's share (Spitz 43.5 → 31 %, ISP 13 → 9 %) and
   lifts the ceiling by ~40 %: faster and each carrier sees less.

The only large software lever left is the share policy itself (e.g. letting Starlink take
what the Spitz can't, or more ISP), which is a security decision, not a tuning one.
