#!/usr/bin/env python3
"""wire-search: record the raw bytes crossing each modem port while a known data
stream (payload-push.py) is in the tunnel, then search them for any piece of it.
Runs on br-edge; the captures stay on the box and are deleted afterwards.

  python3 wire-search.py SECONDS SEED PACKETS [SIZE] [CHUNK]

Every frame on up0..upN is kept in memory. Afterwards each port's bytes are
searched at every offset for any CHUNK-byte piece (default 16) of the known
stream, taken at every CHUNK-aligned position of it. A random 16-byte piece
appears by chance in tens of MB of unrelated bytes with odds around 1e-23, so
any hit means the data crossed that carrier readable.
"""
import random
import select
import socket
import sys
import time

SECS, SEED, N = float(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
SIZE = int(sys.argv[4]) if len(sys.argv) > 4 else 1000
CHUNK = int(sys.argv[5]) if len(sys.argv) > 5 else 16

# br0 is the tunnel's inside (plaintext) interface: the positive control, where
# the stream must be found; the up* modem ports are what carriers see.
ups = sorted(n for _, n in socket.if_nameindex() if n.startswith("up")) + ["br0"]
socks = {}
for u in ups:
    s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(0x0003))
    s.bind((u, 0))
    s.setblocking(False)
    socks[s.fileno()] = (u, s)
buf = {u: bytearray() for u in ups}
frames = {u: 0 for u in ups}
end = time.time() + SECS
while time.time() < end:
    r, _, _ = select.select(list(socks), [], [], 0.5)
    for fd in r:
        u, s = socks[fd]
        while True:
            try:
                pkt = s.recv(65535)
            except BlockingIOError:
                break
            buf[u] += pkt
            frames[u] += 1

data = random.Random(SEED).randbytes(N * SIZE)
pieces = {bytes(data[i:i + CHUNK]) for i in range(0, len(data) - CHUNK + 1, CHUNK)}
print(f"searching for {len(pieces)} distinct {CHUNK}-byte pieces of the {len(data) / 1e6:.1f} MB stream")
for u in ups:
    b = bytes(buf[u])
    hits = 0
    for off in range(0, max(0, len(b) - CHUNK + 1)):
        if b[off:off + CHUNK] in pieces:
            hits += 1
    label = "tunnel inside (control)" if u == "br0" else "modem port"
    print(f"{u} [{label}]: {frames[u]} frames, {len(b) / 1e6:.1f} MB; pieces of the stream found: {hits}")
