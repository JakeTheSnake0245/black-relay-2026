#!/usr/bin/env python3
"""payload-push: send a long, known pseudo-random data stream through the tunnel and
check it comes back intact. Runs on br-edge; the hub (10.255.1.1) echoes it.

  python3 payload-push.py SEED PACKETS [RATE] [SIZE]

The stream is random.Random(SEED).randbytes(PACKETS * SIZE), cut into PACKETS
ICMP echo requests (SIZE bytes each). The hub's echo replies carry the same bytes
back, so the stream crosses the tunnel once in each direction. Prints how much
came back, byte-exact, and whether the replies came back in order.
"""
import os
import random
import socket
import struct
import sys
import threading
import time

SEED, N = int(sys.argv[1]), int(sys.argv[2])
RATE = float(sys.argv[3]) if len(sys.argv) > 3 else 300.0
SIZE = int(sys.argv[4]) if len(sys.argv) > 4 else 1000
HUB = "10.255.1.1"
data = random.Random(SEED).randbytes(N * SIZE)
ident = os.getpid() & 0xFFFF


def csum(b):
    if len(b) % 2:
        b += b"\0"
    s = sum(struct.unpack(f"!{len(b) // 2}H", b))
    s = (s >> 16) + (s & 0xFFFF)
    s += s >> 16
    return ~s & 0xFFFF


sock = socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_ICMP)
sock.settimeout(1.0)
got, order, done = {}, [], threading.Event()


def rx():
    while not done.is_set():
        try:
            pkt = sock.recv(65535)
        except socket.timeout:
            continue
        ihl = (pkt[0] & 0x0F) * 4
        typ, _, _, pid, seq = struct.unpack("!BBHHH", pkt[ihl:ihl + 8])
        if typ == 0 and pid == ident:
            got[seq] = pkt[ihl + 8:]
            order.append(seq)


th = threading.Thread(target=rx, daemon=True)
th.start()
t0 = time.time()
for i in range(N):
    payload = data[i * SIZE:(i + 1) * SIZE]
    hdr = struct.pack("!BBHHH", 8, 0, 0, ident, i & 0xFFFF)
    hdr = struct.pack("!BBHHH", 8, 0, csum(hdr + payload), ident, i & 0xFFFF)
    sock.sendto(hdr + payload, (HUB, 0))
    lag = t0 + (i + 1) / RATE - time.time()
    if lag > 0:
        time.sleep(lag)
time.sleep(3)
done.set()
th.join()
ok = sum(1 for i in range(N) if got.get(i & 0xFFFF) == data[i * SIZE:(i + 1) * SIZE])
inv = sum(1 for a, b in zip(order, order[1:]) if b < a and a - b < 30000)
print(f"sent {N} packets ({N * SIZE / 1e6:.1f} MB) in {time.time() - t0:.0f} s; "
      f"came back byte-exact: {ok} ({ok / N * 100:.2f}%); replies out of order: {inv}")
