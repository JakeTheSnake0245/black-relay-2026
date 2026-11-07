#!/usr/bin/env python3
"""
lane-stats — watch the bonding spread and reconstruction, live.

Samples /proc/net/dev for a set of interfaces and prints per-interface
packet/bit rates. Point it at the uplink-facing interfaces and the tunnel
interface on either end of the tunnel:

  Hetzner server:  the single public NIC (all lanes arrive here, scrambled)
                   and the tun device (reconstructed aggregate goes out here)
  CWWK edge node:  the three uplink WANs (isp/starlink/5G) and the tun device

If the per-lane rates on the physical interfaces sum to roughly the tun
rate, the tunnel is splitting across lanes and re-aggregating at the tun as
intended. A lane sitting at zero under load means it is not carrying its
share.

No root, no capture, no dependencies. Linux only (reads /proc/net/dev).
Python 3.9+.
"""

import argparse
import json
import sys
import time

FIELDS = [
    "rx_bytes", "rx_pkts", "rx_errs", "rx_drop", "rx_fifo", "rx_frame",
    "rx_compressed", "rx_multicast",
    "tx_bytes", "tx_pkts", "tx_errs", "tx_drop", "tx_fifo", "tx_colls",
    "tx_carrier", "tx_compressed",
]


def read_dev():
    out = {}
    with open("/proc/net/dev") as f:
        for line in f:
            if ":" not in line:
                continue
            name, _, rest = line.partition(":")
            name = name.strip()
            vals = [int(x) for x in rest.split()]
            out[name] = dict(zip(FIELDS, vals))
    return out


def mono():
    return time.clock_gettime(time.CLOCK_MONOTONIC)


def human_bps(bps):
    for unit in ("bit", "Kbit", "Mbit", "Gbit"):
        if bps < 1000:
            return f"{bps:6.1f}{unit}"
        bps /= 1000
    return f"{bps:6.1f}Tbit"


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("ifaces", nargs="+",
                    help="interfaces to watch; prefix one with '=' to mark it "
                         "the aggregate/tun (e.g. =tun0)")
    ap.add_argument("--interval", type=float, default=1.0, help="sample period s")
    ap.add_argument("--json", action="store_true", help="JSON lines output")
    ap.add_argument("--count", type=int, default=0, help="samples then exit (0=inf)")
    args = ap.parse_args()

    watch = []
    agg = set()
    for name in args.ifaces:
        if name.startswith("="):
            name = name[1:]
            agg.add(name)
        watch.append(name)

    prev = read_dev()
    prev_t = mono()
    missing = [i for i in watch if i not in prev]
    if missing:
        print(f"warning: not in /proc/net/dev yet: {', '.join(missing)}",
              file=sys.stderr)

    n = 0
    try:
        while True:
            time.sleep(args.interval)
            cur = read_dev()
            t = mono()
            dt = t - prev_t

            rows = {}
            lane_rx = lane_tx = 0.0
            agg_rx = agg_tx = 0.0
            for name in watch:
                a = prev.get(name)
                b = cur.get(name)
                if not a or not b:
                    continue
                rxb = (b["rx_bytes"] - a["rx_bytes"]) * 8 / dt
                txb = (b["tx_bytes"] - a["tx_bytes"]) * 8 / dt
                rxp = (b["rx_pkts"] - a["rx_pkts"]) / dt
                txp = (b["tx_pkts"] - a["tx_pkts"]) / dt
                drop = (b["rx_drop"] - a["rx_drop"]) + (b["tx_drop"] - a["tx_drop"])
                rows[name] = dict(rx_bps=rxb, tx_bps=txb, rx_pps=rxp,
                                  tx_pps=txp, drop=drop)
                if name in agg:
                    agg_rx += rxb
                    agg_tx += txb
                else:
                    lane_rx += rxb
                    lane_tx += txb

            if args.json:
                print(json.dumps({"t": round(time.time(), 3), "if": rows,
                                  "lanes_rx_bps": lane_rx, "lanes_tx_bps": lane_tx,
                                  "agg_rx_bps": agg_rx, "agg_tx_bps": agg_tx}),
                      flush=True)
            else:
                print(f"--- {time.strftime('%H:%M:%S')} "
                      f"(dt={dt:.2f}s) ---------------------------------")
                for name in watch:
                    r = rows.get(name)
                    if not r:
                        print(f"  {name:<12} (absent)")
                        continue
                    mark = "=" if name in agg else " "
                    print(f" {mark}{name:<12} "
                          f"rx {human_bps(r['rx_bps'])} {r['rx_pps']:7.0f}pps  "
                          f"tx {human_bps(r['tx_bps'])} {r['tx_pps']:7.0f}pps"
                          + (f"  drop={r['drop']}" if r['drop'] else ""))
                if agg:
                    # on the server, lanes arrive as rx and leave the tun as tx;
                    # show whether they balance
                    print(f"  {'lanes sum':<12} rx {human_bps(lane_rx)}"
                          f"            tx {human_bps(lane_tx)}")
                    print(f"  {'agg (tun)':<12} rx {human_bps(agg_rx)}"
                          f"            tx {human_bps(agg_tx)}")
                print(flush=True)

            prev, prev_t = cur, t
            n += 1
            if args.count and n >= args.count:
                break
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
