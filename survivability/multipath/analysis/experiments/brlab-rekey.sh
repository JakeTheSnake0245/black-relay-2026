#!/bin/bash
# rekey test: rotate keys every 30 s on the hub (or site), ping through the tunnel for 150 s
B=/usr/local/bin/brlab; GT=/usr/lib/black-relay/glorytun
side=${1:-hub}
$B up >/dev/null 2>&1 || { echo "lab failed"; exit 1; }
sleep 3
dev=brh; ns=blh; [ "$side" = site ] && { dev=brs; ns=bls; }
ip netns exec $ns $GT set dev $dev kxtimeout 30 >/dev/null 2>&1 || echo "set kxtimeout failed"
ip netns exec $ns $GT set dev $dev | head -2
ip netns exec bls ping -i 0.5 -W 1 -c 300 10.255.1.1 2>/dev/null | awk '
	/icmp_seq/ {split($5, a, "="); s=a[2]+0; if (last && s > last + 1) { printf "  gap: seq %d-%d (%.1f s lost)\n", last, s, (s-last-1)*0.5 } last=s; ok++}
	END {printf "  %d of 300 answered (%.0f%%)\n", ok, ok/3}'
$B down
