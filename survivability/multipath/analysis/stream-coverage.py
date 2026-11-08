#!/usr/bin/env python3
"""stream-coverage: for a known stream pushed with payload-push.py, how much of it
each carrier carried, and in what pieces. Worst case: as if a carrier's lanes
could be decrypted (they can't: see wire-search.py).

  python3 stream-coverage.py site-lanes.csv hub-mapped.csv "UPLINKS=..." DGRAM_LEN [PAYLOAD] [PER]

Test packets are the datagrams of exactly DGRAM_LEN bytes. Upload: their order at
the site (send order) is stream order. Download: their order at the hub (send
order, hub capture mapped to site lanes by lane-ends.py) is stream order.
"""
import collections
import csv
import sys

SITE, HUB, SPEC, DLEN = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
PAY = int(sys.argv[5]) if len(sys.argv) > 5 else 1000
PER = int(sys.argv[6]) if len(sys.argv) > 6 else 6
names = {}
for i, item in enumerate(SPEC.replace("UPLINKS=", "").strip('"').split()):
    names[i] = item.split(":")[0]
LABEL = {"up0": "Starlink", "up1": "(nic1)", "up2": "ISP", "up3": "Spitz"}


def stream(path, d):
    r = [x for x in csv.DictReader(open(path)) if x["dir"] == d and int(x["len"]) == DLEN]
    r.sort(key=lambda x: float(x["t"]))
    return [LABEL.get(names[(int(x["lane"]) - 1) // PER], "?") for x in r]


def report(title, s):
    n = len(s)
    print(f"\n### {title}: {n} packets = {n * PAY / 1e6:.1f} MB of the stream\n")
    print("| carrier | share carried | longest unbroken stretch | stream in stretches ≥ 4 KB | complete 4 KB blocks | complete 16 KB blocks | complete 64 KB blocks |")
    print("|---|---|---|---|---|---|---|")
    for m in sorted(set(s), key=lambda m: -s.count(m)):
        mine = [x == m for x in s]
        share = sum(mine) / n
        runs, cur = [], 0
        for x in mine:
            if x:
                cur += 1
            elif cur:
                runs.append(cur)
                cur = 0
        if cur:
            runs.append(cur)
        longest = max(runs) if runs else 0
        in4 = sum(r for r in runs if r >= 4) / n

        def blocks(k):
            full = sum(1 for b in range(0, n - k + 1, k) if all(mine[b:b + k]))
            return full / (n // k), share ** k
        b4, b16, b64 = blocks(4), blocks(16), blocks(64)
        f = lambda b: f"{b[0] * 100:.1f}% (random: {b[1] * 100:.1f}%)"
        print(f"| {m} | {share * 100:.1f}% | {longest} packets = {longest * PAY / 1000:.0f} KB | {in4 * 100:.1f}% | {f(b4)} | {f(b16)} | {f(b64)} |")


report("Upload (site → hub)", stream(SITE, "up"))
report("Download (hub → site)", stream(HUB, "down"))
