# Black Relay — Phase 8 lab results

Environment: local Ubuntu 26.04 VM (Lima `kbuild`, single datapath vCPU,
aarch64). Three-lane netns lab (`gt-lab/lab.sh`) with `tc netem`. Glorytun
built from `ysurac/glorytun@203c5f2` (stock) and the Black Relay fork
(`glorytun-fork/`). Measured with `analysis/relay-probe.py`. Date 2026-10-26.

These are lab figures on one vCPU — they prove correctness and relative
behaviour, not the throughput ceiling of the real N100 hardware (which has
AES-NI and 4 cores). Re-run 8.0 on hardware for absolute numbers.

## Lanes

| lane     | delay      | rate (reorder test) | rate (aggregation test) | loss |
|----------|------------|---------------------|-------------------------|------|
| isp      | 20 ms ±2   | 300 Mbit            | 8 Mbit                  | 0.1% |
| starlink | 45 ms ±8   | 150 Mbit            | 5 Mbit                  | 0.5% |
| cell     | 60 ms ±25  | 40 Mbit             | 3 Mbit                  | 1%   |

## Reordering / reconstruction (CoT-like 500 pkt/s, 400 B, 8 s)

| mode | scheduler | reseq | out-of-order | reorder depth | loss  | p50 | p99 | jitter |
|------|-----------|-------|--------------|---------------|-------|-----|-----|--------|
| stock baseline       | random (stock) | n/a | **38.7 %** | 52 | 0.28 % | 7.2 | 83.9 | 14.0 |
| A patched, neutral   | random | off | 39.3 % | 50 | 0.58 % | 6.4 | 81.5 | 10.2 |
| B arrival only       | arrival | off | **0 %** | 0 | 0.03 % | 6.0 | 10.2 | 1.66 |
| C1 reseq only        | random | on (60 ms) | **0 %** | 0 | 2.86 % | 36.4 | 65.5 | 4.15 |
| C2 arrival + reseq   | arrival | on (60 ms) | **0 %** | 0 | 0.12 % | 5.0 | 49.3 | 1.85 |

(latency columns are relative one-way delay in ms: p50/p99/jitter)

Reading these:

- **A ≈ stock.** The fork in stock-wire-compatible mode (random, no reseq)
  reorders exactly like stock — the sequence number and the patched code add
  no behavioural change until a feature is switched on.
- **B: the arrival scheduler alone removes reordering at this load** by
  sending everything on the fastest link (its backlog never builds at 1.6
  Mbit), so nothing is sprayed onto a slower path. p99 latency 84 → 10 ms.
- **C1: the resequencer alone reconstructs perfect order** from the 39 %-
  out-of-order sprayed stream (ooo 0). The cost is 2.86 % loss: random spray
  puts some packets on the 72 ms one-way cell path, past the 60 ms deadline,
  so they are dropped as stragglers.
- **C2: arrival + reseq is the production combo** — in order (ooo 0), low
  latency (p50 5 ms), and low loss (0.12 %, essentially just link loss),
  because arrival keeps stragglers off the slow link and reseq guarantees
  order for the rest.

## Inverse multiplexing / bandwidth aggregation

Lanes lowered to 8/5/3 Mbit (aggregate 16, best single link 8) so the test
sits under the single-vCPU tunnel ceiling. Random scheduler (spreads across
all links) + resequencer. UDP, 1200 B, 10 s:

| offered | received       | loss | jitter |
|---------|----------------|------|--------|
| 14 Mbit | **13.8 Mbit**  | 0 %  | 1.1 ms |

13.8 Mbit delivered in order with 0 % loss, against a best single link of 8
Mbit — the flow aggregated across all three links and was reconstructed at
the far end. This is inverse multiplexing working end to end.

## Tunnel throughput ceiling (lab artifact, not a hardware result)

- Raw single isp lane, no tunnel: **265 Mbit** (netem 300).
- Single TCP flow through the encrypted tunnel: **~21 Mbit**.

The tunnel is single-threaded and the lab VM has one datapath vCPU doing
encrypt + decrypt + both netns softirq, so one flow caps well below a single
link. This is why the aggregation test uses low-rate lanes. On the N100
(AES-NI, 4 cores) the ceiling is far higher; measure it in 8.0. `glorytun
bench` on the N100 is the number that matters.

## Security hardening (2026-10-26)

Two fixes over upstream, both validated in the lab:

- **Monotonic nonce.** Stock uses the 6-byte µs timestamp as the AEAD nonce;
  two data packets stamped in the same µs would reuse a nonce (a real break
  for ChaCha20-Poly1305). The fork forces the timestamp strictly increasing
  (even values, low bit reserved for the control flag), so nonce reuse is
  impossible by construction. No new cleartext, no behaviour change: C2
  re-measured at ooo 0, loss 0.09 %, p50 4.6 ms — identical to before.
- **Anti-replay window.** Stock has none — a captured packet replays for up
  to 10 min (only the ±10 min clock check). The fork adds a 2048-packet
  sliding window (RFC 6479 style) over the decrypted sequence number, sized
  to tolerate bonded reordering.

Replay injection test: a 300 pkt/s flow for 10 s (2997 delivered, in order),
while 60 real tunnel packets captured off the isp lane were re-injected. The
receiver reported **dup = 0** — every replay dropped at the crypto layer,
and legitimate heavily-reordered traffic was unaffected (ooo 0, loss 0.1 %).

## Throughput — receive-path batching

The mud socket is now non-blocking and the receive side drains all available
packets per wakeup (bonded ingress from three links) instead of one per
select(). No regression: C2 re-measured at ooo 0, loss 0.14 %. On this
single-vCPU lab the tunnel is crypto-bound (~21 Mbit/flow), so batching's
syscall savings are modest here; the larger lever (UDP GSO / sendmmsg) is a
hardware-side task and is noted but not landed. Measure the real ceiling with
`glorytun bench` on the N100.

## Header protection

The 6-byte timestamp field (also the AEAD nonce) is XOR-masked with a keyed
mask derived from a ciphertext sample (QUIC-style), keyed off the static
tunnel key so unmasking is deterministic and independent of key rotation.
Applied to all packets before the MSG/nonce fields are read.

Timestamp field captured on the isp lane (first 6 payload bytes):

    HP off:  293d2c7ac95e 15942c7ac95e b9d92c7ac95e 3a0e3c7ac95e ...
             (the high time bytes `..2c7ac95e`/`..3c7ac95e` are stable and
              increment — the send order is readable on the wire)
    HP on:   cab25f07072c 0e0a4cf25586 2097b7623075 005d402118ac ...
             (random per packet, no readable ordering signal)

Reconstruction unaffected with HP on (ooo 0, loss 0). Both ends must match.

## FEC (XOR parity)

Codec unit-tested in isolation (`src/fec.c -DFEC_TEST`): every single-loss
case across group sizes 2–16 rebuilt bit-exact; two-loss groups correctly
not recovered. End to end, random scheduler + reseq, 5 % loss on every lane,
500 pkt/s:

| config  | delivered loss | corrupt | overhead |
|---------|----------------|---------|----------|
| FEC off | 4.89 %         | 0       | 0        |
| FEC N=8 | 4.28 %         | 0       | ~12 %    |
| FEC N=4 | 2.79 %         | 0       | ~25 %    |

corrupt = payload-CRC mismatches at the receiver: **0 everywhere**, so every
FEC-reconstructed packet was byte-correct. Smaller N recovers more (fewer
multi-loss groups) at higher overhead — the adaptive knob (`mud_fec_set_n`).
Residual loss is multi-loss groups, which XOR cannot recover (Reed-Solomon
would; future work). Parity currently rides a scheduler-chosen path; pinning
parity to a different path than its group would raise recovery further.

## Scatter scheduler (maximal egress disorder)

`GT_SCHED=scatter` sends consecutive sequence numbers round-robin across the
running links (ignoring rate weight), so adjacent packets take different-
latency paths and overtake each other. 600 pkt/s, 300 B:

| mode                     | out-of-order on wire | corrupt | delivered ooo |
|--------------------------|----------------------|---------|---------------|
| scatter, reseq off       | **66.3 %** (depth 73)| 0       | 66.3 %        |
| scatter, reseq on        | —                    | 0       | **0 %**       |

So the stream leaves maximally interleaved and is reconstructed to perfect
order at the far end. 66 % is near the ceiling for round-robin over 3 links:
a packet counts as out-of-order only if a higher-numbered one already
arrived, so the packets that establish new highs (~1/3, the fastest path)
cannot. Literal 100 % is not a meaningful target with a fixed path set; a
sender-side reverse-window shuffle could push it to ~90 % at the cost of
added egress latency (not enabled — latency is precious for CoT).

## Adaptive FEC (closed loop)

`GT_FEC=auto`: the sender reads its own forward-loss telemetry
(`path->tx.loss` from the stat exchange) once a second and sets the group
size N — <0.5 % loss → N=32, <1 % → 16, <3 % → 8, <6 % → 4, else 2. No
feedback channel added; it uses loss the sender already learns.

At 5 % loss/lane, instantaneous delivered loss as the loop settles:

    window 1 (0-6s):  4.49 %   (N at startup 8, adapting)
    window 2 (6-12s): 3.27 %
    window 3 (12-18s):3.20 %   (settled at the N=4 tier 5% selects)

Converges to the fixed-N=4 result (2.79 %), 0 corrupt — the loop measures
loss and tightens redundancy on its own, no operator input.

## Status

- Lab, tunnel, and measurement tools: working and validated.
- Fork (`glorytun-fork/`), all validated in-lab and building reproducibly:
  arrival scheduler, in-AEAD sequence number, receive-side resequencer,
  monotonic-nonce fix, anti-replay window, header protection, XOR FEC with a
  runtime group-size knob, and receive-path batching. Runtime switches via
  env (GT_SCHED, GT_RESEQ[_MS/_WIN], GT_HP, GT_FEC).
- Not yet done: closed-loop adaptive FEC (drive N from measured loss),
  Reed-Solomon multi-loss FEC, parity-path pinning, ctl-based switches
  (env vars for now), one-way-delay export, GSO/sendmmsg, OpenWrt/Debian
  packaging, hardware 8.0 baseline, node-failover epoch handling.

## Packaged build (2026-10-30)

Static musl builds from `packaging/build.sh` (zig cross-compile, libsodium
1.0.20 linked in). The arm64 `.deb` was installed in the `kbuild` VM, and
`black-relay-lab` was run against the installed binary. The x86_64 binary
was run under qemu-user (version, keygen, bench). Shipped defaults:
`GT_SCHED=scatter GT_RESEQ=1 GT_RESEQ_MS=150 GT_HP=1 GT_FEC=auto`. 500 pkt/s,
400 B, 8-10 s per run. ooo 0 and corrupt 0 in every row.

| scheduler | hold   | loss       | loss, Starlink spike (250 ms ±80) | p50 / p99 |
|-----------|--------|------------|-----------------------------------|-----------|
| scatter   | 50 ms  | **21.2 %** | **55.0 %**                        | 49 / 58   |
| scatter   | 100 ms | 0.35 %     | —                                 | 42 / 80   |
| scatter   | 150 ms | 0.00–0.10 %| **34.0 %**                        | 35–46 / 94–118 |
| arrival   | 50 ms  | 0.00 %     | 0.06 %                            | 5 / 9     |
| arrival   | 150 ms | 0.05 %     | 0.00 %                            | 5 / 77    |

Reading these:

- With scatter, the hold must cover the slowest link's lag behind the
  fastest. At 50 ms, cell stragglers (60 ms ±25 against ISP's 20 ms) miss
  the deadline and about 1/5 of traffic is dropped. 150 ms covers it.
- Scatter is fragile when one link stalls. Round-robin keeps feeding the
  spiking link, so its share is lost until the hold covers the spike.
  Arrival routes around the spike with no loss.
- Open decision: scatter (disorder on the wire) vs arrival (latency and
  resilience), or a hybrid that scatters only across links within the hold
  budget. Retune `GT_RESEQ_MS` on the real links.

## Multi-site hub and verification tooling (2026-10-30, br3)

Lab: the hub has one public IP (198.18.0.1) in the vps namespace. The site
has three uplinks, each with its own DHCP-style default route. Shipped
defaults (scatter, hold 150 ms, HP on, FEC auto).

- **Enrollment:** `black-relay-hub add alpha` → token. On the site,
  `black-relay-setup join <token>` with no other arguments found all three
  uplinks, built one routing table per uplink (7100–7102), and brought up 3
  paths. The hub learned all three from one UDP port. A bad site name, a
  duplicate site, a damaged token and a non-existent interface were all
  refused.
- **`rate auto`** needs a ceiling. Without tx/rx it starts at 0 and passes
  no traffic. Capped at 1 Gbit: 500 pkt/s, 0.57 % loss, ooo 0. It cut the
  lossy 5G lane's rate hard, which scatter ignores.
- **br-verify, clean run** (site + hub captures, key given):
  routing PASS on 4,675 outer packets. Dispersion 100 % (true round-robin
  by sender timestamps). Disorder on the wire at the hub 66.5 % (matches the
  66.3 % scatter figure above). Lane transit (relative) ISP 6 ms, Starlink
  34 ms, 5G 69 ms → suggested `GT_RESEQ_MS ≥ 134`, consistent with the
  150 ms default. Inner packets: 0.13 % lost, 0 duplicated, **0 out of order**.
- **br-verify, injected faults:** an ISP-sourced packet forced out the
  5G interface → 3 × MISROUTE on that lane. An overlay-sourced packet sent
  outside the tunnel → 1 × LEAK. Exit status 1.
- **Header unmasking** with the key gives sender wall-clock µs (mod 2^48).
  This confirms the HP key derivation, and that lab capture happens after
  netem (5G packets captured ~89 ms after their send timestamp).
- **Security finding F2:** one control-message nonce reuse in a 14 s
  capture. Two control messages on Starlink and 5G carried the same nonce
  under the static key, with different plaintext. Inherited from upstream.
  The data path is unaffected. See `glorytun-fork/SECURITY.md` F2. The
  "monotonic nonce" result above holds for data packets only.

## br4: stability fixes (2026-10-30)

Same lab: hub on one public IP, site on three uplinks, real
`black-relay@`-style helpers, shipped defaults (scatter, hold 150 ms,
scatter budget 90 ms, HP on, FEC auto, roles client/server).

| check | br3 | br4 |
|---|---|---|
| site restart, hub left running | 0 of 1,800 delivered until the new process caught up with the old one's packet count | recovers in < 3 s: 39 of 40 restarts across all runs; 16/16 on the shipping build (12 site restarts, every third probed immediately, plus 4 hub restarts). The one miss came before the F4 control-socket fix |
| Starlink spike (250 ms ±80), scatter | 34 % loss | **2.6 % loss** (budget skips the spiking lane once its RTT shows it) |
| steady, scatter | 0.10 % | 0.10 %, dispersion 100 %, disorder on the wire 66.5 % |
| arrival, steady / spike | 0 % / 0.06 % | 0 % / 0 % |
| control-message nonce reuse (br-verify --key) | 1 in 14 s | 0 in 30 s, both directions (≈24,000 packets) |
| inner delivery (two-way, 30 s) | — | up 0.03 % lost, down 0 %, 0 out of order, 0 duplicated |
| tunnel control after a sudo/ssh session ends | "tunnel not found" (socket deleted with /run/user/0) | stable (/run/glorytun.0) |

Remaining spike loss is the first moments of the spike, before the lane's
RTT estimate rises past the budget. arrival avoids it entirely at the cost
of disorder on the wire under light load.
