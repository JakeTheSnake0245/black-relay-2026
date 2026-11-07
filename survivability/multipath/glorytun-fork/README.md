# Black Relay — Glorytun fork

Inverse-multiplexing / bonding with far-end reconstruction, as a minimal,
isolated patch on `ysurac/glorytun@203c5f2` (the commit OMR pins). ~450
lines; it does not touch the key exchange, the control-message format, or
the path/rate machinery.

## What it adds

1. **In-AEAD sequence number** (`MUD_SEQ_SIZE` = 8 bytes). Every data packet
   carries a monotonic per-sender counter *inside* the encryption, so the
   far end can reassemble order. On the wire it is ciphertext — not a
   readable field. Control messages are unchanged. Data packets are 8 bytes
   larger; `mud_get_mtu()` accounts for it.
2. **Arrival-aware scheduler** (`mud_select_path_arrival`). Sends each packet
   on the link where it is predicted to arrive first:
   `owd + (backlog + size)/rate`. Idle → everything on the fastest link,
   nothing reordered; under load the fast link's backlog grows until a
   slower link is the earlier delivery, so slower links take the overflow.
   No link is ever switched off. Selectable at runtime; the stock weighted-
   random scheduler remains the default.
3. **Receive-side resequencer** (`src/reseq.c`). Buffers packets and releases
   them to the tun device in sequence order. A packet waiting on a missing
   earlier one is held until the gap fills or a deadline expires (then the
   missing one is counted lost and later packets flow). Bounded window and
   hold time.

4. **Security hardening.** The AEAD nonce (the timestamp field) is forced
   strictly monotonic, so two packets can never share a nonce (stock could
   reuse one within a microsecond — a real break for ChaCha20). A 2048-packet
   anti-replay window (RFC 6479 style) over the decrypted sequence number
   rejects replays, which stock does not do at all.
5. **Header protection.** The timestamp field is XOR-masked QUIC-style, keyed
   off the static tunnel key, so the wire carries no readable, monotonic
   ordering signal. Deterministic to unmask; independent of key rotation.
6. **FEC (XOR parity).** Every N data packets, one parity packet is emitted
   (marked by the seq top bit); the receiver rebuilds a single lost packet
   per group without waiting out the resequencer deadline. N is a runtime
   knob (`mud_fec_set_n`) — the adaptive lever. Codec is unit-tested
   (`cc -DFEC_TEST -Isrc src/fec.c`).
7. **Receive-path batching.** The mud socket is non-blocking and drained per
   wakeup, so bonded ingress from all links is absorbed without a syscall per
   packet.
8. **Restart- and failover-safe sequence numbers.** Each process starts its
   data sequence at wall-clock microseconds, so a restarted sender (reboot,
   service restart, Node 01 → Node 02 with the same key) always continues
   above everything the previous process sent. The far end accepts it at
   once. Before, the sequence restarted at 0 and the far end discarded the
   new stream as replays until it caught up with the old count. When the
   resequencer sees a jump larger than its window, it releases what it
   holds in order and restarts at the new stream.
9. **Control-message nonces unique (F2).** Control timestamps are forced
   strictly increasing like data, and an implicit role byte in the AEAD
   nonce (`GT_ROLE`) keeps the two ends apart under the shared static key.
   Decryption tries the expected role first, so any `GT_ROLE` combination
   still interoperates.
10. **Budget-aware scatter.** Scatter only uses lanes whose one-way delay
    (RTT/2) trails the fastest by at most `GT_SCATTER_BUDGET_MS`. A spiking or
    congested lane is skipped until it recovers, instead of losing its
    share past the resequencer hold.
11. **Stable control socket.** Root always uses `/run/glorytun.0` (or
    `GT_RUNDIR`), never `/run/user/0`, which logind deletes when the last
    root session ends.

Both ends must run this build (the data wire format changed). A "stock"
switch keeps the random scheduler and the resequencer off; in that mode the
only wire difference from stock is the 8-byte sequence field.

## Runtime switches (lab: environment variables)

Set on the `glorytun bind` process. The scheduler matters on the **sender**,
the resequencer on the **receiver** — so in the asymmetric Black Relay setup
the edge node sets `GT_SCHED` and the Hetzner server sets `GT_RESEQ` (and
vice-versa for the download direction).

| var            | default | meaning                                  |
|----------------|---------|------------------------------------------|
| `GT_SCHED`     | random  | `arrival` (low-latency) or `scatter` (max dispersion) |
| `GT_RESEQ`     | 0       | `1` enables the receive-side resequencer |
| `GT_RESEQ_MS`  | 50      | max hold on a gap, ms                     |
| `GT_RESEQ_WIN` | 1024    | reorder window, packets                   |
| `GT_HP`        | 0       | `1` enables timestamp header protection   |
| `GT_FEC`       | 0       | FEC group size N (>=2 fixed; `auto` adaptive; 0 off) |
| `GT_SCATTER_BUDGET_MS` | 60 % of `GT_RESEQ_MS` | scatter skips lanes trailing the fastest by more than this (one-way) |
| `GT_ROLE`      | unset   | `client` or `server`: separates the two ends' control-message nonces |

These move to the `glorytun set` ctl path before hardware rollout (Phase 8
§6.1); env vars are for lab A/B and instant rollback.

## Build

    ./build.sh            # clones, checks out 203c5f2, applies the patch, builds

Or by hand, against a checkout of `ysurac/glorytun@203c5f2` with submodules:

    cp reseq.c reseq.h <glorytun>/src/
    cd <glorytun> && git apply 0001-black-relay-bonding-reseq.patch
    # add src/reseq.c to the build (see build.sh for the gcc line)

## Files

- `0001-black-relay-bonding-reseq.patch` — the diff vs stock.
- `reseq.c`, `reseq.h` — the resequencer (new files; also included in the
  patch, provided separately for convenience).
- `build.sh` — reproducible clone + apply + build.

## Validated

See `../RESULTS.md`. In the three-lane lab: in-order reconstruction of a
39 %-out-of-order sprayed stream (ooo → 0), and 13.8 Mbit aggregated across
8/5/3 Mbit links with 0 % loss.
