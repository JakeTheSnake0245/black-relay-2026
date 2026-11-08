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

## Conclusion

The site's scheduler picks lanes randomly and in proportion to the caps: no pattern, no
memory, no round-robin, equal use of each modem's lanes. Downloads are split exactly as weighted;
their arrival order clusters because the lanes are TCP, which the hub-side scheduler cannot
change. An observer on any one carrier sees only that carrier's encrypted lanes and its random
share of the traffic. This is statistical randomness of path choice; confidentiality rests on the
tunnel's encryption, not on the randomness.

## Re-run

```
# on the CWWK host (br-edge = CT 101)
pct push 101 multipath/analysis/lane-capture.py /root/lane-capture.py
pct exec 101 -- sh -c 'python3 /root/lane-capture.py 72 /root/lanes.csv /root/leaks.json & sleep 4; \
  ping -q -i 0.003 -s 1000 -w 60 10.255.1.1; wait'
# copy lanes.csv back, then
python3 multipath/analysis/lane-randomness.py lanes.csv "$(grep ^UPLINKS /etc/black-relay/br0.conf)"
```

Raw data of this run (timings, lanes, sizes only): `archive/lane-test-20261108/` (local).
