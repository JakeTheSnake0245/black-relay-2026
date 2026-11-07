# Black Relay — analysis tools

Two standalone diagnostics for the bonded tunnel. Pure Python 3.9+, no
dependencies, Linux (both read Linux-only interfaces / use UDP sockets).
Copy them to the Hetzner server and/or a CWWK edge node and run over SSH.

## `relay-probe.py` — end-to-end latency / reorder / loss

Measures what the far end of the tunnel actually receives: relative one-way
delay, jitter, out-of-order count, max reorder depth, loss. Runs *inside*
the tunnel so it sees the real bonded behaviour.

On the Hetzner end (receiver):

    ./relay-probe.py recv --listen :9999

On the edge (sender), send to the Hetzner tunnel-side address, CoT-like:

    ./relay-probe.py send --to 10.255.0.1:9999 --rate 20 --size 200 --echo

Bulk-ish test: `--rate 1000 --size 1200`. `--echo` also measures RTT at the
sender. `--json` on the receiver emits one JSON object per interval for
logging into docs/lab-results.md.

Clock note: the two hosts' clocks are not synced, so one-way delay is
reported *relative* to the running minimum (the queueing + jitter part,
which is what the reorder budget cares about). RTT via `--echo` is absolute.

## `lane-stats.py` — bonding spread and reconstruction, live

Samples `/proc/net/dev`, no root or capture. Shows traffic splitting across
the uplinks and coming back together at the tunnel interface.

On the Hetzner server (one public NIC in, tun out):

    ./lane-stats.py eth0 =wg0        # mark the tun with '='

On a CWWK edge node (three uplinks + tun):

    ./lane-stats.py wan_isp wan_star wan_5g =tun0

Under load the physical-lane rates should sum to roughly the tun rate. A
lane stuck at zero while the others are busy is not carrying its share.

## Lab

`../gt-lab/lab.sh` builds a three-lane netns lab (isp/starlink/cell with tc
netem) to exercise both tools and, later, the tunnel itself, with no
hardware. `sudo ./lab.sh up`, then run the tools inside the namespaces with
`sudo ./lab.sh exec vps ...`.

Validated 2026-10-26 in a local Ubuntu VM: probe loss matches netem loss,
jitter tracks netem jitter, reorder count/depth match netem reorder, and
lane-stats shows per-lane rates correctly.
