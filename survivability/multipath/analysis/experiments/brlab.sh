#!/bin/bash
# brlab: Black Relay multipath, production-shaped, in network namespaces.
#   site (glorytun client + 6 wss lanes per uplink) -- 3 carrier links (netem) -- router -- hub (wstunnel TLS + glorytun server)
# Carrier profiles: env SL_*, SP_*, IS_* (down/up Mbit, one-way delay ms, loss %, buffer ms).
set -euo pipefail
GT=/usr/lib/black-relay/glorytun; WST=/usr/local/bin/wstunnel; W=/tmp/brlab; L=${L:-6}
S=bls; R=blr; H=blh
# name idx down up delay_ms loss% buf_ms
PROFILES=${PROFILES:-"starlink 1 80 10 55 1.0 60
spitz 2 8 3 80 0.1 400
isp 3 274 125 55 0.0 40"}
x() { ip netns exec "$@"; }
down() { for n in $S $R $H; do
	if ip netns list | grep -qw "$n"; then ip netns pids "$n" | xargs -r kill 2>/dev/null || true; sleep 0.3; ip netns del "$n" || true; fi
	done; rm -rf $W; }
shape() { # ns dev rate_mbit delay_ms loss buf_ms
	local lim=$(( $3 * 1000000 / 8 * $6 / 1000 / 1500 + 10 ))
	x $1 tc qdisc replace dev $2 root netem rate ${3}mbit delay ${4}ms loss ${5}% limit $lim
}
up() {
	down; mkdir -p $W
	for n in $S $R $H; do ip netns add $n; x $n ip link set lo up; done
	ip link add r-h netns $R type veth peer name h-r netns $H
	x $R ip addr add 10.9.0.1/24 dev r-h; x $R ip link set r-h up
	x $H ip addr add 10.9.0.2/24 dev h-r; x $H ip link set h-r up
	x $R sysctl -qw net.ipv4.ip_forward=1
	echo "$PROFILES" | while read -r name i dn up dl loss buf; do
		ip link add s-$name netns $S type veth peer name r-$name netns $R
		x $S ip addr add 10.1.$i.1/24 dev s-$name; x $S ip link set s-$name up
		x $R ip addr add 10.1.$i.2/24 dev r-$name; x $R ip link set r-$name up
		x $H ip addr add 10.9.$i.1/32 dev h-r
		x $R ip route add 10.9.$i.1/32 via 10.9.0.2
		x $S ip route add 10.9.$i.1/32 via 10.1.$i.2 dev s-$name
		x $H ip route add 10.1.$i.0/24 via 10.9.0.1
		shape $R r-$name $dn $dl $loss $buf     # download direction (towards the site)
		shape $S s-$name $up $dl $loss $buf     # upload direction
	done
	for n in $S $H; do x $n sysctl -qw net.ipv4.tcp_congestion_control=${CC_LANES:-cubic}; done
	x $S sysctl -qw net.ipv4.tcp_congestion_control=${CC_SITE:-bbr}
	x $H sysctl -qw net.ipv4.tcp_congestion_control=${CC_HUB:-cubic}
	[ -n "${LOWAT:-}" ] && x $H sysctl -qw net.ipv4.tcp_notsent_lowat=$LOWAT || true
	$GT keygen >$W/key 2>/dev/null || head -c32 /dev/urandom | od -An -tx1 | tr -d ' \n' >$W/key
	# hub: glorytun server + wstunnel server (TLS, restrict to the tunnel port)
	( cd $W; x $H env GT_SCHED=random GT_RESEQ=1 GT_RESEQ_MS=${HOLD:-400} GT_RESEQ_WIN=1024 GT_HP=1 GT_FEC=0 GT_PASSIVE_TIMEOUT_S=30 GT_ROLE=server \
		$GT bind dev brh keyfile $W/key from addr 0.0.0.0 port 5001 >$W/gt-hub.log 2>&1 & )
	( cd $W; x $H $WST server --log-lvl ERROR --restrict-to 127.0.0.1:5001 wss://0.0.0.0:443 >$W/wst-hub.log 2>&1 & )
	sleep 1
	x $H ip addr add 10.255.1.1/30 dev brh; x $H ip link set brh up mtu ${MTU:-1400}
	# site: glorytun client, L lanes per uplink
	( cd $W; x $S env GT_SCHED=random GT_RESEQ=1 GT_RESEQ_MS=${HOLD:-400} GT_RESEQ_WIN=1024 GT_HP=1 GT_FEC=0 GT_KEEPALIVE_MS=${KEEP:-200} GT_ROLE=client GT_MTU=${MTU:-1400} \
		$GT bind dev brs keyfile $W/key from addr 127.0.0.1 port 5001 >$W/gt-site.log 2>&1 & )
	sleep 1
	x $S ip addr add 10.255.1.2/30 dev brs; x $S ip link set brs up mtu ${MTU:-1400}
	k=0
	echo "$PROFILES" | while read -r name i dn up dl loss buf; do
		for j in $(seq 0 $((L - 1))); do
			k=$(( (i - 1) * L + j + 1 ))
			( x $S $WST client --log-lvl ERROR --websocket-ping-frequency 10s \
				-L "udp://127.0.1.$k:5001:127.0.0.1:5001?timeout_sec=0" wss://10.9.$i.1:443 >>$W/wst-site.log 2>&1 & )
		done
	done
	sleep 2
	caps "${CAPS:-1000/1000 1000/1000 500/300}"
	x $H iperf3 -s -D -B 10.255.1.1 >/dev/null
	if [ -n "${PACE:-}" ]; then
		printf 'PORT=5001\nWSS_LANES=%s\nUPLINKS="s-starlink:%s s-spitz:%s s-isp:%s"\n' $L ${CAPS:-1000/1000 1000/1000 500/300} >$W/br0.conf
		( x $S env BR_DEV=brs BR_CONF=$W/br0.conf python3 /usr/local/bin/br-pace >$W/pace.log 2>&1 & )
	fi
	for _ in $(seq 1 20); do x $S ping -c1 -W1 10.255.1.1 >/dev/null 2>&1 && { echo "lab up (lanes $L, hub cc ${CC_HUB:-cubic}, hold ${HOLD:-400})"; return 0; }; sleep 1; done
	echo "tunnel did not come up"; return 1
}
# caps "SL_tx/SL_rx SP_tx/SP_rx IS_tx/IS_rx" (Mbit per uplink; like the sliders)
caps() { set -- $1; for i in 1 2 3; do m=${!i}; tx=${m%/*}; rx=${m#*/}
	for j in $(seq 0 $((L - 1))); do k=$(( (i - 1) * L + j + 1 ))
		x $S $GT path dev brs addr 127.0.0.1 to addr 127.0.1.$k port 5001 set up rate fixed tx $((tx * 125000 / L)) rx $((rx * 125000 / L)) >/dev/null
	done; done; }
# dl/ul LABEL [flows] [secs]: goodput through the tunnel, inner sender cubic
srv() { pkill -f "iperf3 -s" 2>/dev/null || true; sleep 0.5; x $H iperf3 -s -D -B 10.255.1.1 >/dev/null; sleep 0.5; }
dl() { srv; x $S iperf3 -c 10.255.1.1 -R -P ${2:-4} -t ${3:-20} -C cubic -J 2>/dev/null | python3 /usr/local/bin/brlab-parse.py "$1" down; }
ul() { srv; x $S iperf3 -c 10.255.1.1 -P ${2:-4} -t ${3:-20} -C cubic -J 2>/dev/null | python3 /usr/local/bin/brlab-parse.py "$1" up; }
case "${1:-}" in up) up ;; down) down ;; caps) caps "$2" ;; dl) dl "${2:-test}" "${3:-4}" "${4:-20}" ;; ul) ul "${2:-test}" "${3:-4}" "${4:-20}" ;; *) echo "brlab up|down|caps|dl|ul"; exit 2 ;; esac
