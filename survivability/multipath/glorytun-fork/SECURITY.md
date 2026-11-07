# Black Relay glorytun fork — security analysis

Scope: the code this fork adds to `ysurac/glorytun@203c5f2` — the sequence
number, resequencer (`reseq.c`), FEC (`fec.c`), scatter scheduler, header
protection, nonce fix, and anti-replay window. Date 2026-10-26.

## Threat model

Every byte the receiver parses from a peer is first AEAD-decrypted and
authenticated (AEGIS-256 or ChaCha20-Poly1305), so an off-path attacker
cannot forge or mutate the sequence number, FEC parity fields, or payload —
a bit-flip fails the MAC and the packet is dropped. The post-decrypt parsers
(`fec_dec_parity`, the resequencer, the parity branch in `mud_recv`)
therefore face only inputs produced by a peer holding the key.

We still harden these parsers to memory-safety perfection, as defense in
depth against: a compromised or malfunctioning peer, a bug in our own
encoder, and future changes that might expose a parser to unauthenticated
input. The on-path network attacker is handled by the crypto; these notes
are about not trusting even authenticated structure blindly.

## Method

1. `fec.c` codec correctness unit test (`-DFEC_TEST`) under AddressSanitizer
   + UndefinedBehaviorSanitizer.
2. An adversarial fuzz harness (`fuzz_harness.c`) driving `fec_dec_parity`
   and the resequencer with random/malformed group sizes, lengths, parity
   blocks and sequence numbers under ASan+UBSan (400k iterations each).
3. Manual review of every added parse point and all buffer/length/index
   arithmetic.

## Findings

### F1 — stack buffer overflow in `fec_dec_parity` (FIXED)

`plen` (the rebuilt packet's length, read from the first 2 bytes of the
recovered XOR unit) was bounds-checked as `plen > (size_t)maxlen - 2`. When
`maxlen` was 0 or 1, `(size_t)maxlen - 2` underflowed to ~2^64, so the check
always passed and a `plen` up to 65535 was accepted, overrunning the
`FEC_UNIT_MAX` (1600-byte) `acc`/`out_buf` stack buffers on the subsequent
copy. ASan caught it in the fuzz harness.

A valid sender never emits `maxlen < 2` (the unit always carries its 2-byte
length prefix), and the field is authenticated, so this was not reachable by
a network attacker — but a buggy/compromised peer or encoder could trigger
it.

Fix: reject `maxlen < 2` up front (which also makes `maxlen - 2` safe), and
clamp each member's XOR length to `maxlen` so a member can never be XORed
past the parity block. Re-run of the fuzz harness: clean.

### F2 — control-message nonce reuse under the static key (FIXED in br4, inherited from upstream)

Found 2026-10-30 by `br-verify` on lab captures (`packaging/debug/`). The
monotonic-nonce fix (`last_tx_time` in `mud_send`) covers **data** packets
only. Control messages go through `mud_send_msg()`, which encrypts with
`keyx.private`, the **static tunnel key**, and uses `MUD_MSG_MARK(now)` as the
nonce. When the per-path loop sends control messages on two paths within the
same microsecond, both carry the same nonce under the same key with
different plaintext, because each path's address and counters differ.
Observed: Starlink and 5G control messages with identical unmasked
timestamps and identical first 16 ciphertext bytes, once in a 14 s capture
(3 lanes). Upstream glorytun behaves the same.

Exposure: AEAD nonce reuse. With ChaCha20-Poly1305 it leaks the XOR of the
two plaintexts and reuses the Poly1305 one-time key, which can enable
forgery of control messages under that nonce. AEGIS-256 is not
nonce-misuse resistant either. Control messages carry path stats, addresses
and the key-exchange public key. Data packets are unaffected: they use the
rotating session keys and strictly unique nonces. The full impact (for
example, whether a forged control message could steer the key exchange) has
not been worked through.

The two ends (and the two edge nodes) also share the static key, so a hub
and a site control message stamped in the same microsecond collide too. A
complete fix needs both:
1. a strictly increasing per-process counter for control timestamps (odd
   values, as data uses even), and
2. per-direction separation under the static key, e.g. a sender-role byte
   in the unused AEAD nonce bytes, or per-direction keys derived via KDF.

Detection: `br-verify` reports `NONCE REUSE` per direction, and tags each
packet in the annotated pcapng.

Fix (br4), both parts:
1. `mud_send_msg()` forces control timestamps strictly increasing per
   process (`last_msg_time`, odd values), like the data path.
2. An implicit role byte goes in the AEAD nonce after the 6-byte timestamp
   (`npub[6]`, never transmitted). Client = 1, server = 2, unset = 0, from
   `GT_ROLE`; the `black-relay@` tunnels set it from their ROLE, and the
   OMR `.ipk` ships `client`. The receiver tries the expected role first,
   then the others, so mismatched or unset roles still interoperate. With
   the two ends set differently, their control nonces can never coincide
   under the shared key. Cost: at most two extra control-message decrypt
   attempts.

Verified: 30 s two-way capture (≈24,000 outer packets, both directions,
3 lanes), `br-verify --key`: every nonce unique in both directions. The
same setup on br3 showed a reuse within 14 s. Not interoperable with br3
and older: upgrade both ends together.

### F3 — restarted sender silenced by the receiver's replay window (FIXED in br4)

The data sequence started at 0 in every process. The receiver never reset
its anti-replay window or resequencer. So after a sender restart (reboot,
service restart, Node 01 → Node 02 failover) every new packet looked like
an old replay. Delivery stopped until the new process had sent as many
packets as the old one, which is hours or days for a long-running node.
Reproduced in the lab: 0 of 1,800 packets delivered after a site restart.

Fix: the sequence starts at wall-clock microseconds, so a new process
always continues above the old one. Replays of the old traffic stay behind
the window, and anti-replay is unchanged. The resequencer releases its
buffer in order on a jump bigger than its window. Verified: 39 of 40
restarts (site and hub) recovered within 3 s, 16/16 on the shipping build.
The one miss came before the F4 fix and matches its symptom (a restart
left with no paths).

### F4 — control socket vanishing with login sessions (FIXED in br4, inherited)

For root, glorytun placed its control socket under `/run/user/0` whenever
that directory existed. logind creates it per session (sudo, ssh) and
deletes it when the last session ends. The running tunnel then became
uncontrollable: `path` and `show` reported "tunnel not found", and a
restart could come up with no paths. Fix: root uses `/run/glorytun.0`
(or `GT_RUNDIR`). An availability issue, not a confidentiality one.

## Reviewed and found sound

- **`mud_encrypt` / `mud_decrypt`** — plaintext is `[seq][inner]`; both check
  the combined size against `MUD_PKT_MAX_SIZE` and decrypt into a
  full-size scratch buffer before copying out. No overflow for any packet
  length up to the socket MTU.
- **Anti-replay window** — index is `(seq/64) % MUD_REPLAY_WORDS`, always in
  range; the advance loop is bounded by the window size (2048) or replaced
  by a single `memset`. Parity packets (seq top bit set) are handled on a
  separate path and never enter the window, so they cannot pollute it.
- **Header protection** — samples 16 bytes of ciphertext at a fixed offset;
  no-ops for packets too small to carry the sample; reads and writes stay
  within the packet buffer.
- **Scatter scheduler** — the running-path array is bounded by
  `MUD_PATH_MAX`; round-robin index is taken modulo the live count.
- **Arrival scheduler** — integer math (`(backlog+size)*1e6/rate`) cannot
  overflow 64-bit for realistic backlog; division guarded against a
  zero-rate path.
- **Resequencer** — per-packet length clamped to the slot size before copy;
  the ring window is clamped to `RESEQ_WIN_MAX` (65536), so a bad
  `GT_RESEQ_WIN` cannot request an unbounded allocation; emit path writes a
  blocking tun, so recovered/ordered packets are never silently dropped.

## Security improvements this fork makes over upstream

- **Nonce reuse eliminated for data packets.** Stock uses the µs timestamp
  as the AEAD nonce; two packets in one µs reuse a nonce (catastrophic for
  ChaCha20-Poly1305). The fork forces data nonces strictly monotonic, and
  since br4 control nonces too, with the two ends separated (F2).
- **Anti-replay added.** Stock has none (only a ±10-min clock window); a
  captured packet replays for minutes. The fork adds a 2048-packet sliding
  window. Validated by injecting 60 captured packets → 0 delivered.
- **Header protection.** The timestamp/nonce field is masked on the wire, so
  it is no longer a readable, monotonic ordering oracle.

## Residual / out of scope

- XOR FEC recovers one loss per group by design; multi-loss groups are not
  recovered (Reed-Solomon would be — future work). This is availability, not
  confidentiality or integrity.
- The static header-protection key is derived from the tunnel key and does
  not rotate. It protects a non-secret field (the timestamp), not payload
  confidentiality, so this is acceptable; payload secrecy still rests on the
  rotating AEAD keys, unchanged from upstream.
- No change to upstream's key exchange, cipher selection, or forward secrecy.
- This review covers the fork's additions, not a full audit of upstream mud.
