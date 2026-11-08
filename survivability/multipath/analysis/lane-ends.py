#!/usr/bin/env python3
"""lane-ends: join a site capture (lane-capture.py) and a hub capture
(hub-lane-capture.py) taken at the same time.

  python3 lane-ends.py site-lanes.csv hub-lanes.csv OUT-hub-mapped.csv

1. Maps each hub lane socket (port) to its site lane (127.0.1.k): a lane is one TCP
   connection, so its datagrams keep their order and size end to end; the size
   sequences of a hub port and its site lane line up.
2. Writes the hub capture with site lane numbers (for lane-randomness.py: the hub's
   download order is the hub scheduler's true order).
3. Prints, per lane: packets each end saw, matched pairs, one-way delay spread; and
   overall how out of order packets were on the wire (sent order vs arrival order).
"""
import collections
import csv
import statistics
import sys

SITE, HUB, OUT = sys.argv[1], sys.argv[2], sys.argv[3]
MIN = 500   # data packets only


def load(path, key):
    d = collections.defaultdict(lambda: {"up": [], "down": []})
    for r in csv.DictReader(open(path)):
        d[int(r[key])][r["dir"]].append((float(r["t"]), int(r["len"])))
    for v in d.values():
        for k in v:
            v[k].sort()
    return d


site, hub = load(SITE, "lane"), load(HUB, "port")


def align(a, b):
    """Best offset aligning two size sequences (a = sender's, b = receiver's).
    Returns (offset, matched fraction) where a[i] pairs with b[i - offset]."""
    sa, sb = [n for _, n in a], [n for _, n in b]
    best = (0, 0.0)
    for off in range(-60, 61):
        pairs = [(sa[i], sb[i - off]) for i in range(len(sa)) if 0 <= i - off < len(sb)]
        if len(pairs) < 30:
            continue
        frac = sum(1 for x, y in pairs if x == y) / len(pairs)
        if frac > best[1]:
            best = (off, frac)
    return best


# map hub port -> site lane using both directions' size sequences
score = {}
for p, hv in hub.items():
    for k, sv in site.items():
        s1 = align(hv["down"], sv["down"])[1] if hv["down"] and sv["down"] else 0
        s2 = align(sv["up"], hv["up"])[1] if hv["up"] and sv["up"] else 0
        score[(p, k)] = (s1 + s2) / 2
mapping, used = {}, set()
for (p, k), sc in sorted(score.items(), key=lambda x: -x[1]):
    if p in mapping or k in used or sc < 0.9:
        continue
    mapping[p] = k
    used.add(k)

print(f"mapped {len(mapping)} of {len(hub)} hub lane sockets to site lanes "
      f"(match quality ≥ {min(score[(p, k)] for p, k in mapping.items()):.3f})")

with open(OUT, "w") as f:
    f.write("t,dir,lane,len\n")
    for p, k in mapping.items():
        for d in ("up", "down"):
            for t, n in hub[p][d]:
                f.write(f"{t:.6f},{d},{k},{n}\n")

# per-lane delivery and delay, using the aligned pairs
print("\n| lane | path | down sent (hub) | down got (site) | up sent (site) | up got (hub) | down delay spread p50/p95 ms |")
print("|---|---|---|---|---|---|---|")
send_order, recv_time, STALLED = [], {}, set()
for p, k in sorted(mapping.items(), key=lambda x: x[1]):
    path = ["Starlink", "(nic1)", "ISP", "Spitz"][(k - 1) // 6]
    hd = [x for x in hub[p]["down"] if x[1] >= MIN]
    sd = [x for x in site[k]["down"] if x[1] >= MIN]
    su = [x for x in site[k]["up"] if x[1] >= MIN]
    hu = [x for x in hub[p]["up"] if x[1] >= MIN]
    off, _ = align(hd, sd)
    delays = []
    for i, (t, n) in enumerate(hd):
        j = i - off
        if 0 <= j < len(sd) and sd[j][1] == n:
            delays.append(sd[j][0] - t)
            send_order.append((t, (k, i)))
            recv_time[(k, i)] = sd[j][0]
    if delays:
        base = min(delays)
        rel = sorted((d - base) * 1000 for d in delays)
        spread = f"{statistics.median(rel):.0f} / {rel[int(0.95 * (len(rel) - 1))]:.0f}"
        if rel[int(0.95 * (len(rel) - 1))] > 1000:
            STALLED.add(k)
    else:
        spread = "–"
    print(f"| {k} | {path} | {len(hd)} | {len(sd)} | {len(su)} | {len(hu)} | {spread} |")

# out of order on the wire: neighbours in the hub's send order that arrive swapped
send_order.sort()
arr = [(recv_time[key], key[0]) for _, key in send_order]
def swapped(seq):
    return sum(1 for (a, _), (b, _) in zip(seq, seq[1:]) if b < a), max(1, len(seq) - 1)
s, n = swapped(arr)
print(f"\ndownload: {len(arr)} matched data packets; {s} of {n} neighbouring pairs ({s / n * 100:.1f}%) "
      "arrived swapped (out of order on the wire; the resequencer puts them back)")
# the same without lanes that stalled for over a second (p95 spread > 1000 ms)
if STALLED:
    s2, n2 = swapped([x for x in arr if x[1] not in STALLED])
    print(f"without stalled lane(s) {sorted(STALLED)}: {s2} of {n2} ({s2 / n2 * 100:.1f}%) swapped")

