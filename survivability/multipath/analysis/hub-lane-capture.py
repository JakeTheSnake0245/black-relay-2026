#!/usr/bin/env python3
"""hub-lane-capture: the hub end of lane-capture.py. Records the hub tunnel's
packets to and from each lane socket, in order, headers only.

Run from the BR2026 host inside the hub container's network namespace:
  sudo nsenter -t "$(docker inspect -f '{{.State.Pid}}' survivability-black-relay)" -n \
    python3 hub-lane-capture.py SECONDS OUT.csv

Each site lane arrives as its own wstunnel UDP socket 127.0.0.1:<port> talking to
glorytun on 127.0.0.1:5001. glorytun -> <port> = download sent on that lane (the
hub scheduler's order); <port> -> glorytun = upload received on that lane.
"""
import select
import socket
import struct
import sys
import time

SECS, OUT = float(sys.argv[1]), sys.argv[2]
s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(0x0003))
s.bind(("lo", 0))
s.setblocking(False)
rows, end = [], time.time() + SECS
while time.time() < end:
    if not select.select([s], [], [], 0.5)[0]:
        continue
    while True:
        try:
            pkt, addr = s.recvfrom(65535)
        except BlockingIOError:
            break
        if addr[2] != 4 or len(pkt) < 42 or pkt[12:14] != b"\x08\x00" or pkt[23] != 17:
            continue
        ihl = (pkt[14] & 0x0F) * 4
        sport, dport, ulen = struct.unpack("!HHH", pkt[14 + ihl:14 + ihl + 6])
        if sport == 5001 and dport != 5001:
            rows.append((time.time(), "down", dport, ulen - 8))
        elif dport == 5001 and sport != 5001:
            rows.append((time.time(), "up", sport, ulen - 8))
with open(OUT, "w") as f:
    f.write("t,dir,port,len\n")
    for t, d, p, n in rows:
        f.write(f"{t:.6f},{d},{p},{n}\n")
print(f"hub: captured {len(rows)} lane packets")
