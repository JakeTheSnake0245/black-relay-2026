# black-relay-debug

A testing and debugging package, kept separate from the tunnel package. It
captures each uplink and the tunnel device **independently**, checks that
every packet went where it should, and writes one annotated `.pcapng` for
Wireshark.

| file | where | what |
|---|---|---|
| `br-capture` | site + hub (`/usr/sbin`) | one tcpdump per interface, stop together; `meta.env` records addresses/gateways |
| `br-verify` | anywhere with Python 3 (`/usr/bin`, also runs on macOS) | route check, per-lane delivery, inner delivery, annotated pcapng |
| `black-relay.lua` | your Wireshark machine | dissector for the outer tunnel packets |

`apt install ./black-relay-debug_<ver>_all.deb` pulls in `tcpdump`. The
`black-relay-debug-<ver>.tar.gz` holds `br-verify` and the dissector for
the Mac.

## Run a check

At the same time on both ends:

    hub$  sudo br-capture --name site-alpha --seconds 60     # or --name br0 for a single-tunnel server
    site$ sudo br-capture --seconds 60                       # uplinks from /etc/black-relay/br0.conf + tun

Push traffic during the window: `relay-probe.py send ...`, iperf3, or real use.
Then copy both directories to one machine and run:

    br-verify ./br-capture-site-... --peer ./br-capture-hub-... --key br0.key

`--key` is optional. It unmasks the header timestamps, which shows send
order and disorder on the wire. Treat the key and the captures as
sensitive: the tun captures hold up to 256 bytes of inner plaintext per
packet (`--full` keeps everything).

## What the report checks

- **Uplink routing:** every outer tunnel packet left through the uplink that
  owns its source address (`MISROUTE` otherwise). Replies came back on the
  same uplink (`MISDELIVERED`). No overlay-addressed or cross-uplink packet
  left outside the tunnel (`LEAK`). Exit status is 0 only if all of this is clean.
- **Lane share and dispersion:** each lane's share of sent packets, and how
  often consecutive packets changed lane. Round-robin scatter is near 100 %.
- **Lanes end to end** (`--peer`): every outer packet is matched across the
  Internet by its ciphertext. Reported per lane: loss, relative transit,
  the address the lane arrives at the hub as (after NAT), and a suggested
  `GT_RESEQ_MS` from the lane spread.
- **Disorder on the wire** (`--peer --key`): share of data packets that
  reached the hub after a later-sent packet. The resequencer removes this.
- **Inner packets** (`--peer`): every packet on the site tun matched on the
  hub tun, per direction: delivered, lost, duplicated, out of order. Out of
  order should be 0, since the resequencer is the point.

## In Wireshark

Open `black-relay-annotated.pcapng`. Each captured interface is its own
Wireshark interface, named `site:<if> uplink <addr>` / `hub:<if> ...`.
Every tunnel packet carries a comment, for example:

    BR up lane=enp2s0 route=OK send#=1532 data
    BR up lane=enp2s0 from 203.0.113.7:40211 (site pkt enp2s0#88)
    BR MISROUTE lane=enp3s0: src 192.168.1.20 belongs to enp2s0, expected 100.64.3.9
    BR inner up LOST (not on the hub tun)

Useful display filters:

    frame.comment contains "MISROUTE" || frame.comment contains "LEAK"
    frame.comment contains "lane=wwan0"
    frame.comment contains "LOST"
    frame.interface_name contains "uplink"
    blackrelay                                   (with the dissector installed)

Add `frame.comment` as a column for a one-line-per-packet view. The two
hosts' clocks differ, so in the merged timeline the hub's packets are offset
by the clock difference. Compare lanes against each other, not against
absolute time.
