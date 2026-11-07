#!/usr/bin/env python3
"""peek-ts — print the first 6 UDP-payload bytes (glorytun timestamp field)
of tunnel packets on an interface, to show whether header protection makes
the field unreadable. Run in a namespace: python3 peek-ts.py <iface> <port> <count>"""
import socket, struct, sys
iface, port, count = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(0x0003))
s.bind((iface, 0)); s.settimeout(8)
seen = 0
while seen < count:
    try:
        f = s.recv(65535)
    except socket.timeout:
        break
    if len(f) < 14 + 20 + 8 or struct.unpack("!H", f[12:14])[0] != 0x0800:
        continue
    ip = f[14:]; ihl = (ip[0] & 0x0F) * 4
    if ip[9] != 17:
        continue
    udp = ip[ihl:]; dport, ulen = struct.unpack("!H", udp[2:4])[0], struct.unpack("!H", udp[4:6])[0]
    if dport != port:
        continue
    payload = udp[8:ulen]
    if len(payload) < 6:
        continue
    print(payload[:6].hex())
    seen += 1
