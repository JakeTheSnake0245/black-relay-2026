#!/usr/bin/env python3
"""
relay-probe — end-to-end measurement for the Black Relay bonded tunnel.

Two roles:

  recv   Run on the Hetzner end. Listens for probe packets that came up
         through the tunnel, and reports what it is actually receiving:
         one-way delay (relative), jitter, out-of-order count, reorder
         depth and loss. This answers "what is the far end getting?".

  send   Run on the edge (a CWWK node, or a host behind it). Emits
         sequenced, timestamped UDP through the tunnel at a configurable
         rate and size. CoT-like default: 20 pkt/s, 200 B.

The probe runs *inside* the tunnel (send to the tunnel-side address of the
peer), so it measures the bonded path end to end, including whatever
reordering the links introduce and whatever reconstruction the tunnel does.

No third-party dependencies. Python 3.9+.

Clocks: edge and server clocks are not synced, so absolute one-way delay is
not meaningful. We report *relative* OWD (each sample minus the running
minimum), which is exactly the queueing + jitter component and is what the
reorder budget cares about. RTT is available with --echo.
"""

import argparse
import json
import signal
import socket
import struct
import sys
import time
import zlib

MAGIC = 0x42524C50  # "BRLP"
# wire: magic u32 | flags u32 | seq u64 | send_ns u64 | crc32 u32 | padding
# crc32 is over the payload bytes after the header, so a FEC-reconstructed or
# otherwise corrupted packet is detected end to end.
HDR = struct.Struct("!IIQQI")
FLAG_ECHO_REQ = 1
FLAG_ECHO_RSP = 2


def _pattern(seq, n):
    # deterministic per-seq payload so the receiver can verify content
    return bytes((seq + i) & 0xFF for i in range(n))


def now_ns():
    return time.clock_gettime_ns(time.CLOCK_REALTIME)


def mono_ns():
    return time.clock_gettime_ns(time.CLOCK_MONOTONIC)


# ---------------------------------------------------------------- percentiles
def pct(sorted_vals, q):
    if not sorted_vals:
        return 0.0
    if len(sorted_vals) == 1:
        return float(sorted_vals[0])
    pos = (len(sorted_vals) - 1) * q
    lo = int(pos)
    hi = min(lo + 1, len(sorted_vals) - 1)
    frac = pos - lo
    return sorted_vals[lo] * (1 - frac) + sorted_vals[hi] * frac


# ---------------------------------------------------------------------- recv
def run_recv(args):
    # SIGINT is ignored when started as a background job, and SIGTERM comes
    # from kill/systemd/timeout: route both to the FINAL report.
    def _stop(signum, frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGINT, _stop)
    signal.signal(signal.SIGTERM, _stop)

    host, _, port = args.listen.rpartition(":")
    host = host or "::"
    port = int(port)

    fam = socket.AF_INET6 if ":" in host or host == "::" else socket.AF_INET
    s = socket.socket(fam, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    if fam == socket.AF_INET6:
        try:
            s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        except OSError:
            pass
    s.bind((host, port))
    s.settimeout(1.0)

    print(f"relay-probe recv: listening on [{host}]:{port}", file=sys.stderr)

    # metrics
    first_seq = None
    lowest_seq = None
    highest_seq = -1
    recv_count = 0
    reorder_count = 0          # packets that arrived after a higher seq
    max_reorder_depth = 0      # highest_seq - seq at arrival
    dup_count = 0
    corrupt_count = 0          # payload crc mismatch (integrity failure)
    seen = set()
    owd_samples = []           # relative one-way delay, ms
    owd_min_ns = None
    jitter = 0.0               # RFC 3550 interarrival jitter, ms
    prev_transit_ns = None
    first_arrival_mono = None
    last_arrival_mono = None
    bytes_recv = 0
    last_report = mono_ns()
    report_every_ns = int(args.interval * 1e9)

    def summary(final=False):
        losts = 0
        span = 0
        if lowest_seq is not None and highest_seq >= 0:
            # span runs from the lowest to the highest seq actually seen, so
            # reordered-but-present packets never count as loss
            span = highest_seq - lowest_seq + 1
            losts = span - len(seen)
        s_owd = sorted(owd_samples)
        dur = 0.0
        if first_arrival_mono is not None and last_arrival_mono is not None:
            dur = (last_arrival_mono - first_arrival_mono) / 1e9
        rate = recv_count / dur if dur > 0 else 0.0
        thr = bytes_recv * 8 / dur / 1e6 if dur > 0 else 0.0
        rec = {
            "t": round(time.time(), 3),
            "recv": recv_count,
            "lost": max(losts, 0),
            "lost_pct": round(100 * losts / span, 3) if span else 0.0,
            "dup": dup_count,
            "corrupt": corrupt_count,
            "ooo": reorder_count,
            "ooo_pct": round(100 * reorder_count / recv_count, 3) if recv_count else 0.0,
            "reorder_depth_max": max_reorder_depth,
            "owd_rel_ms": {
                "p50": round(pct(s_owd, 0.50), 3),
                "p95": round(pct(s_owd, 0.95), 3),
                "p99": round(pct(s_owd, 0.99), 3),
                "max": round(s_owd[-1], 3) if s_owd else 0.0,
            },
            "jitter_ms": round(jitter, 3),
            "rate_pps": round(rate, 1),
            "throughput_mbit": round(thr, 3),
        }
        if args.json:
            print(json.dumps(rec), flush=True)
        else:
            tag = "FINAL" if final else "live "
            print(
                f"[{tag}] recv={rec['recv']:>7} lost={rec['lost']:>5} "
                f"({rec['lost_pct']:>5.2f}%) corrupt={rec['corrupt']:>4} "
                f"ooo={rec['ooo']:>5} depth={rec['reorder_depth_max']:>3} "
                f"owd_rel p50/p95/p99={rec['owd_rel_ms']['p50']:.1f}/"
                f"{rec['owd_rel_ms']['p95']:.1f}/{rec['owd_rel_ms']['p99']:.1f}ms "
                f"jit={rec['jitter_ms']:.2f}ms "
                f"{rec['rate_pps']:.0f}pps {rec['throughput_mbit']:.1f}Mbit",
                flush=True,
            )

    try:
        while True:
            try:
                data, peer = s.recvfrom(65535)
            except socket.timeout:
                if mono_ns() - last_report >= report_every_ns:
                    summary()
                    last_report = mono_ns()
                continue
            arrival_mono = mono_ns()
            arrival_real = now_ns()
            if len(data) < HDR.size:
                continue
            magic, flags, seq, send_ns, crc = HDR.unpack_from(data, 0)
            if magic != MAGIC:
                continue

            if flags & FLAG_ECHO_REQ:
                # bounce it straight back so the sender can get RTT
                rsp = bytearray(data)
                HDR.pack_into(rsp, 0, MAGIC, FLAG_ECHO_RSP, seq, send_ns, crc)
                s.sendto(rsp, peer)

            # end-to-end integrity: payload must match its crc
            if (zlib.crc32(data[HDR.size:]) & 0xFFFFFFFF) != crc:
                corrupt_count += 1

            recv_count += 1
            bytes_recv += len(data)
            if first_arrival_mono is None:
                first_arrival_mono = arrival_mono
            last_arrival_mono = arrival_mono

            # relative one-way delay (clock offset cancels out of the min)
            transit_ns = arrival_real - send_ns
            if owd_min_ns is None or transit_ns < owd_min_ns:
                owd_min_ns = transit_ns
            owd_samples.append((transit_ns - owd_min_ns) / 1e6)

            # RFC 3550 interarrival jitter
            if prev_transit_ns is not None:
                d = abs(transit_ns - prev_transit_ns) / 1e6
                jitter += (d - jitter) / 16.0
            prev_transit_ns = transit_ns

            # ordering
            if first_seq is None:
                first_seq = seq
            if lowest_seq is None or seq < lowest_seq:
                lowest_seq = seq
            if seq in seen:
                dup_count += 1
            else:
                seen.add(seq)
            if seq < highest_seq:
                reorder_count += 1
                depth = highest_seq - seq
                if depth > max_reorder_depth:
                    max_reorder_depth = depth
            if seq > highest_seq:
                highest_seq = seq

            if mono_ns() - last_report >= report_every_ns:
                summary()
                last_report = mono_ns()
    except KeyboardInterrupt:
        pass
    finally:
        print(file=sys.stderr)
        summary(final=True)


# ---------------------------------------------------------------------- send
def run_send(args):
    host, _, port = args.to.rpartition(":")
    port = int(port)
    infos = socket.getaddrinfo(host, port, type=socket.SOCK_DGRAM)
    fam, _, _, _, sa = infos[0]
    s = socket.socket(fam, socket.SOCK_DGRAM)
    if args.bind:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind((args.bind, 0))

    size = max(args.size, HDR.size)
    padlen = size - HDR.size
    interval = 1.0 / args.rate if args.rate > 0 else 0.0
    flags = FLAG_ECHO_REQ if args.echo else 0

    rtts = []
    if args.echo:
        s.settimeout(0)

    print(
        f"relay-probe send: -> {host}:{port} rate={args.rate}pps "
        f"size={size}B count={args.count or 'inf'} echo={bool(args.echo)}",
        file=sys.stderr,
    )

    seq = 0
    start = mono_ns()
    next_send = start
    sent = 0
    try:
        while True:
            if args.count and sent >= args.count:
                break
            if args.duration and (mono_ns() - start) / 1e9 >= args.duration:
                break
            payload = _pattern(seq, padlen)
            crc = zlib.crc32(payload) & 0xFFFFFFFF
            pkt = bytearray(HDR.size + padlen)
            HDR.pack_into(pkt, 0, MAGIC, flags, seq, now_ns(), crc)
            pkt[HDR.size:] = payload
            s.sendto(pkt, sa)
            seq += 1
            sent += 1

            if args.echo:
                # drain any echoes without blocking
                while True:
                    try:
                        data, _ = s.recvfrom(65535)
                    except (BlockingIOError, OSError):
                        break
                    if len(data) < HDR.size:
                        continue
                    m, fl, _sq, snd, _crc = HDR.unpack_from(data, 0)
                    if m == MAGIC and fl & FLAG_ECHO_RSP:
                        rtts.append((now_ns() - snd) / 1e6)

            next_send += int(interval * 1e9)
            sleep = (next_send - mono_ns()) / 1e9
            if sleep > 0:
                time.sleep(sleep)
    except KeyboardInterrupt:
        pass

    dur = (mono_ns() - start) / 1e9
    print(f"sent {sent} packets in {dur:.2f}s ({sent/dur:.1f} pps)", file=sys.stderr)
    if args.echo and rtts:
        r = sorted(rtts)
        print(
            f"rtt n={len(r)} p50/p95/p99="
            f"{pct(r,0.5):.1f}/{pct(r,0.95):.1f}/{pct(r,0.99):.1f}ms",
            file=sys.stderr,
        )


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="role", required=True)

    r = sub.add_parser("recv", help="Hetzner-side receiver/measurer")
    r.add_argument("--listen", default="::", help="[host:]port, default ::9999")
    r.add_argument("--interval", type=float, default=1.0, help="report period s")
    r.add_argument("--json", action="store_true", help="JSON lines output")
    r.set_defaults(func=run_recv)

    t = sub.add_parser("send", help="edge-side generator")
    t.add_argument("--to", required=True, help="host:port (tunnel-side peer addr)")
    t.add_argument("--rate", type=float, default=20.0, help="packets/sec")
    t.add_argument("--size", type=int, default=200, help="packet bytes")
    t.add_argument("--count", type=int, default=0, help="stop after N (0=inf)")
    t.add_argument("--duration", type=float, default=0.0, help="stop after S seconds")
    t.add_argument("--bind", default="", help="source address to bind")
    t.add_argument("--echo", action="store_true", help="request echo, measure RTT")
    t.set_defaults(func=run_send)

    # allow "--listen :9999" convenience
    args = ap.parse_args()
    if args.role == "recv" and ":" not in args.listen and args.listen.isdigit():
        args.listen = "::" + ":" + args.listen
    args.func(args)


if __name__ == "__main__":
    main()
