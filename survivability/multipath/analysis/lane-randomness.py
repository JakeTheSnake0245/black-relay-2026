#!/usr/bin/env python3
"""lane-randomness: statistical checks on which lane the scheduler picked, from a
lane-capture.py CSV (time, direction, lane, length). Stdlib only.

  python3 lane-randomness.py lanes.csv "up0:10/150 up1:100/150 up2:100/150 up3:5/20" [lanes-per-uplink]

Upload order in the capture IS the site scheduler's order (packets leave glorytun
in the order it picks lanes). Download order is the order packets ARRIVED, which
also mixes in each path's latency; its sequence tests are therefore indicative.
Only data packets (>= 500 bytes) count: keepalives go out on every lane on a timer.
"""
import collections
import csv
import math
import sys

CSV, SPEC = sys.argv[1], sys.argv[2]
PER = int(sys.argv[3]) if len(sys.argv) > 3 else 6
MIN_LEN = 500


# ---------------------------------------------------------------- math
def gammq(a, x):
    """Regularized upper incomplete gamma Q(a, x) (Numerical Recipes)."""
    if x <= 0:
        return 1.0
    gln = math.lgamma(a)
    if x < a + 1:   # series for P, return 1 - P
        ap, s, d = a, 1.0 / a, 1.0 / a
        for _ in range(1000):
            ap += 1
            d *= x / ap
            s += d
            if abs(d) < abs(s) * 1e-12:
                break
        return max(0.0, 1.0 - s * math.exp(-x + a * math.log(x) - gln))
    b, c, d = x + 1 - a, 1e300, 1.0 / (x + 1 - a)
    h = d
    for i in range(1, 1000):   # continued fraction for Q
        an = -i * (i - a)
        b += 2
        d = an * d + b
        d = 1e-300 if abs(d) < 1e-300 else d
        c = b + an / c
        c = 1e-300 if abs(c) < 1e-300 else c
        d = 1.0 / d
        de = d * c
        h *= de
        if abs(de - 1) < 1e-12:
            break
    return math.exp(-x + a * math.log(x) - gln) * h


def chi2_p(stat, df):
    return gammq(df / 2.0, stat / 2.0)


def chi2_fit(obs, exp_p):
    n = sum(obs)
    stat = sum((o - n * p) ** 2 / (n * p) for o, p in zip(obs, exp_p) if p > 0)
    df = len([p for p in exp_p if p > 0]) - 1
    return stat, df, chi2_p(stat, df)


def norm_p(z):
    return math.erfc(abs(z) / math.sqrt(2))


def verdict(p, alpha=0.01):
    return "PASS" if p >= alpha else "FAIL"


# ---------------------------------------------------------------- data
spec = {}
for i, item in enumerate(SPEC.replace('UPLINKS=', '').strip('"').split()):
    name, caps = item.split(":")
    tx, rx = (int(x) for x in caps.split("/"))
    spec[i] = (name, tx, rx)

rows = [r for r in csv.DictReader(open(CSV)) if int(r["len"]) >= MIN_LEN]
rows.sort(key=lambda r: float(r["t"]))
out = []
P = out.append


def uplink_of(lane):
    return (lane - 1) // PER


def analyse(direction):
    seq = [int(r["lane"]) for r in rows if r["dir"] == direction]
    if len(seq) < 200:
        P(f"\n### {direction}: only {len(seq)} data packets, skipped")
        return
    mods = [uplink_of(k) for k in seq]
    active = sorted(set(mods))
    capidx = 1 if direction == "up" else 2
    caps = {m: spec[m][capidx] for m in active}
    tot = sum(caps.values())
    exp_p = {m: caps[m] / tot for m in active}
    cnt = collections.Counter(mods)
    n = len(seq)
    P(f"\n### {'Upload (site scheduler order)' if direction == 'up' else 'Download (arrival order at the site)'}: {n} data packets")
    P("\n| path | caps weight | expected | measured | packets |\n|---|---|---|---|---|")
    for m in active:
        P(f"| {spec[m][0]} | {caps[m]} | {exp_p[m]*100:.1f}% | {cnt[m]/n*100:.1f}% | {cnt[m]} |")
    results = []
    st, df, p = chi2_fit([cnt[m] for m in active], [exp_p[m] for m in active])
    results.append(("Share per path matches its caps (chi-square)", f"χ²={st:.2f}, df={df}", p))
    # lanes within each path equally used
    for m in active:
        lc = collections.Counter(k for k in seq if uplink_of(k) == m)
        lanes = [m * PER + j + 1 for j in range(PER)]
        st, df, p = chi2_fit([lc[k] for k in lanes], [1 / PER] * PER)
        results.append((f"Lanes of {spec[m][0]} used equally", f"χ²={st:.2f}, df={df}", p))
    # independence: next path vs previous path (contingency table)
    idx = {m: i for i, m in enumerate(active)}
    T = [[0] * len(active) for _ in active]
    for a, b in zip(mods, mods[1:]):
        T[idx[a]][idx[b]] += 1
    rs = [sum(r) for r in T]
    cs = [sum(T[i][j] for i in range(len(T))) for j in range(len(T))]
    N = sum(rs)
    st = sum((T[i][j] - rs[i] * cs[j] / N) ** 2 / (rs[i] * cs[j] / N)
             for i in range(len(T)) for j in range(len(T)) if rs[i] and cs[j])
    df = (len(T) - 1) ** 2
    results.append(("Next path independent of the previous one", f"χ²={st:.2f}, df={df}", chi2_p(st, df)))
    # runs test on the busiest path vs the rest
    top = cnt.most_common(1)[0][0]
    x = [1 if m == top else 0 for m in mods]
    n1, n0 = sum(x), n - sum(x)
    runs = 1 + sum(1 for a, b in zip(x, x[1:]) if a != b)
    mu = 2 * n1 * n0 / n + 1
    var = 2 * n1 * n0 * (2 * n1 * n0 - n) / (n * n * (n - 1))
    z = (runs - mu) / math.sqrt(var)
    results.append((f"Runs test ({spec[top][0]} vs others)", f"runs={runs}, expected {mu:.0f}, z={z:.2f}", norm_p(z)))
    # autocorrelation of the busiest-path indicator, lags 1..10
    mean = n1 / n
    v = sum((xi - mean) ** 2 for xi in x)
    acs = [sum((x[i] - mean) * (x[i + L] - mean) for i in range(n - L)) / v for L in range(1, 11)]
    worst = max(abs(a) for a in acs)
    z = worst * math.sqrt(n)
    # Bonferroni over 10 lags
    results.append(("No autocorrelation, lags 1-10", f"max |r|={worst:.3f} (noise level {1/math.sqrt(n):.3f})", min(1.0, 10 * norm_p(z))))
    # round-robin inside a path: next lane of the same path = previous + 1?
    last, rr, pairs = {}, 0, 0
    for k in seq:
        m = uplink_of(k)
        if m in last:
            pairs += 1
            rr += ((last[m] - m * PER) % PER + 1) % PER == (k - m * PER - 1) % PER
        last[m] = k
    pr = 1 / PER
    z = (rr - pairs * pr) / math.sqrt(pairs * pr * (1 - pr))
    results.append(("No round-robin within a path", f"next-lane-in-order {rr}/{pairs} = {rr/pairs*100:.1f}% (random: {pr*100:.1f}%)", norm_p(z)))
    # longest streak on one lane vs expectation
    best = cur = 1
    for a, b in zip(seq, seq[1:]):
        cur = cur + 1 if a == b else 1
        best = max(best, cur)
    q = sum((collections.Counter(seq)[k] / n) ** 2 for k in set(seq))
    exp_long = math.log(n * (1 - q)) / -math.log(q) if 0 < q < 1 else 0
    results.append(("Longest streak on one lane", f"{best} in a row (typical for random: ~{exp_long:.0f})",
                    1.0 if best <= 2.5 * exp_long + 3 else 0.0))
    P("\n| test | result | p | verdict |\n|---|---|---|---|")
    for name, res, p in results:
        P(f"| {name} | {res} | {p:.3f} | {verdict(p)} |")
    if direction == "down":
        P("\nDownload order is arrival order (latency differences reorder packets), so its sequence tests are indicative only.")


P("## Lane scheduler randomness")
P(f"\nSource: `{CSV}` · uplinks `{SPEC}` · {PER} lanes per uplink · data packets ≥ {MIN_LEN} bytes · p < 0.01 = FAIL")
analyse("up")
analyse("down")
print("\n".join(out))
