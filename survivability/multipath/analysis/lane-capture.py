#!/usr/bin/env python3
"""lane-capture: record which lane every tunnel packet takes (WSS transport), and
check that nothing but the lanes leaves the modem ports. Runs on br-edge.

  python3 lane-capture.py SECONDS OUT.csv LEAKS.json

Lanes are the local wstunnel clients 127.0.1.<k>:5001 (k = 1..N; uplink index
(k-1) // WSS_LANES). Packets from glorytun to 127.0.1.k are uploads the
scheduler sent on lane k; packets from 127.0.1.k back to glorytun are downloads
the hub sent on lane k. Only headers are read (no payload is stored): time,
direction, lane, length. Stdlib only (AF_PACKET), no tcpdump needed.
"""
import json
import select
import socket
import struct
import sys
import time

SECS, OUT, LEAKS = float(sys.argv[1]), sys.argv[2], sys.argv[3]
HUB = "89.167.30.202"
ETH_P_ALL = 0x0003
PACKET_OUTGOING = 4


def ip4(b):
    return socket.inet_ntoa(b)


def open_sock(ifc):
    s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(ETH_P_ALL))
    s.bind((ifc, 0))
    s.setblocking(False)
    return s


ups = sorted(i for i in (n for _, n in socket.if_nameindex()) if i.startswith("up"))
socks = {"lo": open_sock("lo")}
for u in ups:
    try:
        socks[u] = open_sock(u)
    except OSError:
        pass
by_fd = {s.fileno(): (n, s) for n, s in socks.items()}

rows, leaks = [], {u: {"lanes_tls": 0, "dhcp": 0, "arp_nd": 0, "other": 0, "samples": []} for u in ups}
end = time.time() + SECS
while time.time() < end:
    r, _, _ = select.select(list(by_fd), [], [], 0.5)
    for fd in r:
        name, s = by_fd[fd]
        while True:
            try:
                pkt, addr = s.recvfrom(65535)
            except BlockingIOError:
                break
            ts = time.time()
            if name == "lo":
                if addr[2] != PACKET_OUTGOING or len(pkt) < 42 or pkt[12:14] != b"\x08\x00":
                    continue
                ihl = (pkt[14] & 0x0F) * 4
                if pkt[23] != 17:
                    continue
                src, dst = pkt[26:30], pkt[30:34]
                sport, dport, ulen = struct.unpack("!HHH", pkt[14 + ihl:14 + ihl + 6])
                if dst[:3] == b"\x7f\x00\x01" and dport == 5001:
                    rows.append((ts, "up", dst[3], ulen - 8))
                elif src[:3] == b"\x7f\x00\x01" and sport == 5001:
                    rows.append((ts, "down", src[3], ulen - 8))
                continue
            # a modem port: classify what crosses it
            L = leaks[name]
            et = pkt[12:14]
            if et in (b"\x08\x06",) or (et == b"\x86\xdd" and len(pkt) > 54 and pkt[20] == 58):
                L["arp_nd"] += 1
                continue
            if et != b"\x08\x00" or len(pkt) < 34:
                L["other"] += 1
                continue
            ihl = (pkt[14] & 0x0F) * 4
            proto, src, dst = pkt[23], ip4(pkt[26:30]), ip4(pkt[30:34])
            sp = dp = 0
            if proto in (6, 17) and len(pkt) >= 14 + ihl + 4:
                sp, dp = struct.unpack("!HH", pkt[14 + ihl:14 + ihl + 4])
            if proto == 6 and ((dst == HUB and dp == 443) or (src == HUB and sp == 443)):
                L["lanes_tls"] += 1
            elif proto == 17 and {sp, dp} & {67, 68}:
                L["dhcp"] += 1
            else:
                L["other"] += 1
                if len(L["samples"]) < 8:
                    L["samples"].append(f"proto {proto} {src}:{sp} -> {dst}:{dp}")

with open(OUT, "w") as f:
    f.write("t,dir,lane,len\n")
    for t, d, k, n in rows:
        f.write(f"{t:.6f},{d},{k},{n}\n")
json.dump(leaks, open(LEAKS, "w"), indent=1)
print(f"captured {len(rows)} lane packets; modem ports: " +
      ", ".join(f"{u} tls={v['lanes_tls']} other={v['other']}" for u, v in leaks.items()))
