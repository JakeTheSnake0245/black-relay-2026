#!/usr/bin/env python3
"""
replay-test — capture real tunnel packets on a lane and re-inject them, to
verify the far end's anti-replay window drops them.

Run inside the `site` namespace. Sniffs UDP packets headed to the server
port on the given interface, then resends each captured UDP payload from the
same source address. A correct receiver decrypts them (they are valid) but
rejects them as replays, so nothing reaches the tun and the probe receiver
reports zero duplicates. Without replay protection, the probe would see
duplicates.

Usage (in the site ns, while a probe flow is running):
  python3 replay-test.py <iface> <dst_ip> <port> [count]
"""
import socket
import struct
import sys

ETH_P_IP = 0x0003


def main():
    iface = sys.argv[1]
    dst_ip = sys.argv[2]
    port = int(sys.argv[3])
    count = int(sys.argv[4]) if len(sys.argv) > 4 else 20

    s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(ETH_P_IP))
    s.bind((iface, 0))
    s.settimeout(10)

    captured = []  # (src_ip, payload)
    while len(captured) < count:
        try:
            frame = s.recv(65535)
        except socket.timeout:
            break
        # Ethernet(14) + IPv4
        if len(frame) < 14 + 20 + 8:
            continue
        eth_type = struct.unpack("!H", frame[12:14])[0]
        if eth_type != 0x0800:
            continue
        ip = frame[14:]
        ihl = (ip[0] & 0x0F) * 4
        if ip[9] != 17:  # UDP
            continue
        src_ip = socket.inet_ntoa(ip[12:16])
        d_ip = socket.inet_ntoa(ip[16:20])
        udp = ip[ihl:]
        sport, dport, ulen = struct.unpack("!HHH", udp[0:6])
        if dport != port or d_ip != dst_ip:
            continue
        payload = udp[8:ulen]
        if len(payload) > 30:  # skip tiny control frames, grab data packets
            captured.append((src_ip, payload))

    print(f"captured {len(captured)} tunnel data packets", file=sys.stderr)

    sent = 0
    for src_ip, payload in captured:
        u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            u.bind((src_ip, 0))
            u.sendto(payload, (dst_ip, port))
            u.sendto(payload, (dst_ip, port))  # send twice to be sure
            sent += 2
        except OSError as e:
            print(f"resend from {src_ip} failed: {e}", file=sys.stderr)
        finally:
            u.close()
    print(f"re-injected {sent} replayed packets", file=sys.stderr)


if __name__ == "__main__":
    main()
