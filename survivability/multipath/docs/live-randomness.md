# Live lane randomness check (cwwk01, 2026-11-08)

Does the multipath scheduler really spread traffic randomly over the lanes, in proportion to
each modem's speed caps, without leaking anything outside the lanes? Measured on the live CWWK.

## Setup

- 3 working modems: Starlink (up0), ISP / travel router (up2), Spitz cellular (up3); nic1 empty.
- `TRANSPORT=wss`, 6 HTTPS lanes per modem (18 live), `GT_SCHED=random`, caps
  `up0 10/150 · up2 100/150 · up3 5/20` (up/down Mbit).
- Load: 60 s of 1000-byte pings from br-edge to the hub (~114 packets/s each way) on top of normal
  site traffic. About 7 MB each way; the Spitz carried ~0.7 MB of it.
- Capture: `analysis/lane-capture.py` on br-edge. Each lane is a local wstunnel client
  `127.0.1.k:5001`, so the capture sees exactly which lane every tunnel packet used, in the order
  the scheduler sent it (upload) or the order it arrived (download). Headers only, no contents.
  Data packets ≥ 500 bytes (keepalives go out on every lane on a timer and are left out).
- The same capture watched all four modem ports for anything other than the lanes.

## Results

Upload: the site scheduler's own order. **Every test passes.**

| path | expected (caps) | measured |
|---|---|---|
| Starlink | 8.7% | 8.4% |
| ISP | 87.0% | 87.5% |
| Spitz | 4.3% | 4.1% |

| test | result | verdict |
|---|---|---|
| share per path matches its caps | χ² = 1.83, p = 0.40 | pass |
| lanes inside each path used equally | p = 0.39 / 0.97 / 0.62 | pass |
| next path independent of the previous | χ² = 2.02, p = 0.73 | pass |
| runs test | z = −1.24, p = 0.21 | pass |
| autocorrelation, lags 1–10 | max r = 0.024, p = 0.43 | pass |
| no round-robin inside a path | 17.2% vs 16.7% random, p = 0.25 | pass |
| longest streak on one lane | 5 (random ≈ 4) | pass |

Download: chosen by the hub's scheduler, measured where it arrives at the site. **Shares and lane
use pass**: Starlink 46.5% / ISP 47.3% / Spitz 6.2% against 46.9 / 46.9 / 6.25 expected, p = 0.77.
The order tests fail on the raw arrivals (runs z = −6.0), and the cause is the transport, not the
scheduler: each lane is a TCP connection, and 5.2% of download packets arrive back-to-back on the
same lane under 1 ms apart (0.1% on upload), which is TCP releasing held packets together after a
hiccup on that lane. Counting each such burst as one delivery, the runs test passes (z = −1.75,
p = 0.08). Removing Starlink stalls alone does not change it.

Leaks: none. Apart from the lanes, the modem ports carried only DHCP, ARP/neighbour discovery,
the CWWK's own spanning-tree hellos, the edge's sanctioned checks (Starlink dish probe on
9200, Spitz status on its admin page), and broadcasts arriving from other devices on the ISP
network. The edge's leak-guard drop counter did not move during the run.

Reassembly: 0.19% of test pings lost (Starlink was dropping out every ~1.6 min that day).

## Both ends (second run, same day)

A second 60 s run captured the hub too (`hub-lane-capture.py`, from the BR2026 host inside the
hub container's network, headers only) at the same time as the site. `lane-ends.py` matched
every hub lane socket to its site lane (18 of 18, exact: a lane keeps its packet order and sizes
end to end).

**Hub scheduler, its true send order: every test passes.**

| path | expected (caps) | measured |
|---|---|---|
| Starlink | 46.9% | 47.9% |
| ISP | 46.9% | 45.7% |
| Spitz | 6.25% | 6.4% |

| test | result | verdict |
|---|---|---|
| share per path matches its caps | χ² = 3.89, p = 0.14 | pass |
| lanes inside each path used equally | p = 0.60 / 0.31 / 0.48 | pass |
| next path independent of the previous | χ² = 7.68, p = 0.10 | pass |
| runs test | z = 0.66, p = 0.51 | pass |
| autocorrelation, lags 1–10 | max r = 0.019 | pass |
| no round-robin inside a path | 16.3% vs 16.7% random, p = 0.40 | pass |
| longest streak on one lane | 3 (random ≈ 3) | pass |

The site scheduler (upload) passed every test again in this run (shares 8.6 / 86.7 / 4.7% vs
8.7 / 87.0 / 4.3%). So the download clustering seen at the site in the first run is the TCP
lanes delivering in bursts, not the hub's choices.

**End to end, per lane:** nothing lost on any lane (sent and received counts agree, apart from
packets in flight when a capture window opened or closed). Delay spread inside a lane:
Starlink ~8 ms typical / 30 ms at p95, ISP 1–5 ms, Spitz 2–6 ms. **One Spitz lane (19) stalled:**
some of its packets arrived 6–9 s late, a cellular TCP retransmit stall. They were past the
400 ms reorder hold, so they count as the tunnel's small loss (0.21% of test pings) instead of
holding everything up.

**On the wire:** 23.7% of neighbouring packets (in the hub's send order) arrive at the site
swapped; the resequencer puts them back in order.

## Known data stream: what one carrier could reconstruct (third run)

`payload-push.py` sent a 20 MB pseudo-random stream (20,000 × 1,000 bytes, seed 911) from br-edge
to the hub as pings; the hub echoed it, so it crossed once each way. Meanwhile
`wire-search.py` recorded every raw byte on each modem port and searched it, at every offset, for
any 16-byte piece of the stream (1.25 million pieces). Both ends' lane captures gave which carrier
carried each part (`stream-coverage.py`; the test packets are exactly 1,058 bytes on the lanes).

**Delivered:** 20,000 of 20,000 packets came back byte-exact, 0 out of order.

**What an eavesdropper on one carrier gets: nothing.**

| where | captured | pieces of the stream found |
|---|---|---|
| Starlink port | 17.2 MB | 0 |
| ISP port | 35.7 MB | 0 |
| Spitz port | 6.2 MB | 0 |
| tunnel inside (control, unencrypted) | 41.6 MB | 2,480,000 (the whole stream, both ways) |

**Worst case, as if a carrier's encryption were broken:** what share it carried, and in what pieces.

| carrier | upload share | longest unbroken stretch | complete 4 KB / 16 KB / 64 KB blocks | download share | longest stretch | complete 4 KB / 16 KB / 64 KB |
|---|---|---|---|---|---|---|
| ISP | 86.8% | 47 KB | 56.7% / 10.3% / 0% | 46.5% | 12 KB | 4.5% / 0% / 0% |
| Starlink | 9.0% | 4 KB | 0 / 0 / 0 | 47.4% | 13 KB | 5.1% / 0% / 0% |
| Spitz | 4.2% | 2 KB | 0 / 0 / 0 | 6.1% | 3 KB | 0 / 0 / 0 |

Every block figure equals what pure random spreading predicts (e.g. ISP upload 4 KB: 56.7% vs
56.8%). Downloads are well fragmented: no carrier ever holds 16 KB in one piece. Uploads lean on
the ISP by design (caps 100 vs Starlink 10 and Spitz 5 Mbit up), so in this hypothetical the ISP
holds most of the upload stream in stretches up to ~47 KB. Fragmenting uploads more means giving
the ISP a smaller share, which costs upload speed (Starlink's real upload is ~9 Mbit).

## Conclusion

Both schedulers, the site's (upload) and the hub's (download, measured at the hub), pick lanes
randomly and in proportion to the caps: no pattern, no memory, no round-robin, equal use of each
modem's lanes. Arrival order at the far end clusters a little because each lane is TCP. An observer on any one carrier sees only that carrier's encrypted lanes: a 20 MB known
stream left no readable trace on any carrier, and even with the encryption broken a carrier
would hold only its random share, in pieces. This is statistical randomness of path choice; confidentiality rests on the
tunnel's encryption, not on the randomness.

## Re-run

```
# on the CWWK host (br-edge = CT 101)
pct push 101 multipath/analysis/lane-capture.py /root/lane-capture.py
pct exec 101 -- sh -c 'python3 /root/lane-capture.py 72 /root/lanes.csv /root/leaks.json & sleep 4; \
  ping -q -i 0.003 -s 1000 -w 60 10.255.1.1; wait'
# copy lanes.csv back, then
python3 multipath/analysis/lane-randomness.py lanes.csv "$(grep ^UPLINKS /etc/black-relay/br0.conf)"

# hub end at the same time (on BR2026):
sudo nsenter -t "$(sudo docker inspect -f '{{.State.Pid}}' survivability-black-relay)" -n \
  python3 hub-lane-capture.py 80 /tmp/hub-lanes.csv
# known-stream test (br-edge): payload-push.py SEED PACKETS + wire-search.py SECONDS SEED PACKETS,
# then stream-coverage.py site.csv hub-mapped.csv "<UPLINKS>" 1058
# then
python3 multipath/analysis/lane-ends.py lanes.csv hub-lanes.csv hub-mapped.csv
python3 multipath/analysis/lane-randomness.py hub-mapped.csv "<UPLINKS>" 6 hub
```

Raw data (timings, lanes, sizes only): `archive/lane-test-20261108/` and `.../both-ends/`, `.../payload/` (local).
