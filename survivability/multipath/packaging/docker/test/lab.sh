#!/bin/sh
# Container lab: hub container (published UDP ports, like BR2026) + a site
# container with three uplinks on three docker networks with netem delay/loss.
# The site reaches the hub through the docker host's DNAT, exactly the
# production path. Run as root on a throwaway docker host.
#
#   test/lab.sh up | test | down
set -eu
IMG=${IMG:-black-relay:0.3.4-br4}
HOST_IP=${HOST_IP:-$(ip -4 route get 1.1.1.1 | awk '{for(n=1;n<NF;n++) if($n=="src"){print $(n+1);exit}}')}
W=/tmp/br-lab

up() {
	mkdir -p $W/hub $W/site
	docker network create br-hubnet >/dev/null
	docker run -d --name br-hub --read-only --cap-drop ALL --cap-add NET_ADMIN \
		--device /dev/net/tun --sysctl net.ipv4.ip_forward=1 --security-opt no-new-privileges \
		--tmpfs /run --tmpfs /tmp -e BR_PUBLIC_IP="$HOST_IP" -e BR_PORT_BASE=5000 \
		-v $W/hub:/etc/black-relay -p 5001-5010:5001-5010/udp --network br-hubnet "$IMG" >/dev/null
	sleep 2
	docker exec br-hub black-relay-hub add lab --lan 10.40.0.0/24 | tee $W/add.out
	tok=$(grep '^brj1\.' $W/add.out | sed 's/^brj1\.//' | base64 -d)
	eval "$(echo "$tok" | sed 's/^/export /')"
	printf '%s\n' "$BR_KEY" >$W/site/br0.key; chmod 600 $W/site/br0.key

	# The site has no docker network: three veth "uplinks" from this host into
	# its netns. Its packets then reach the hub like internet traffic does on
	# BR2026 (host DNAT only, source addresses preserved), not bridge-to-bridge.
	docker run -d --name br-site --network none --cap-drop ALL --cap-add NET_ADMIN --cap-add NET_RAW \
		--device /dev/net/tun --tmpfs /run --tmpfs /tmp -e BR_FORWARD=none -e BR_NAT=0 \
		-v $W/site:/etc/black-relay "$IMG" >/dev/null
	pid=$(docker inspect -f '{{.State.Pid}}' br-site)
	for i in 1 2 3; do
		ip link add brlab$i type veth peer name up$i
		ip link set up$i netns "$pid"
		ip addr add 10.201.$i.1/24 dev brlab$i; ip link set brlab$i up
		nsenter -t "$pid" -n sh -c "ip addr add 10.201.$i.2/24 dev up$i && ip link set up$i up"
	done
	nsenter -t "$pid" -n ip route add default via 10.201.1.1
	# lane shapes: "ISP" 10 ms, "Starlink" 35 ms +-10, "5G" 60 ms +-20 with 1 % loss
	nsenter -t "$pid" -n tc qdisc add dev up1 root netem delay 10ms
	nsenter -t "$pid" -n tc qdisc add dev up2 root netem delay 35ms 10ms
	nsenter -t "$pid" -n tc qdisc add dev up3 root netem delay 60ms 20ms loss 1%
	cat >$W/site/br0.conf <<EOF
ROLE=client
DEV=br0
PORT=$BR_PORT
KEYFILE=/etc/black-relay/br0.key
TUN_ADDR=$BR_TUN
SERVER=$BR_HUB
UPLINKS="up1:100:10.201.1.1 up2:50:10.201.2.1 up3:20:10.201.3.1"
GT_RESEQ_MS=150
EOF
	echo "site conf written; supervisor picks it up"
	sleep 6
	docker logs br-site 2>&1 | tail -8
}

t() {
	echo "== hub list"; docker exec br-hub black-relay-hub list
	echo "== hub paths"; docker exec br-hub /usr/lib/black-relay/glorytun path dev br-lab show stat | head
	echo "== ping hub overlay from site"; docker exec br-site ping -c 5 -i 0.3 10.255.1.1 | tail -2
	echo "== relay-probe 10 s through the tunnel (site -> hub)"
	docker exec -d br-hub sh -c 'timeout 13 python3 /usr/share/black-relay/analysis/relay-probe.py recv --listen 10.255.1.1:9999 --interval 5 >/tmp/recv.log 2>&1'
	sleep 1
	docker exec br-site python3 /usr/share/black-relay/analysis/relay-probe.py send --to 10.255.1.1:9999 --echo --rate 200 --duration 10 2>&1 | tail -8
	sleep 3; echo "-- hub receiver:"; docker exec br-hub cat /tmp/recv.log | tail -12
	echo "== site egress via hub NAT (1.1.1.1 routed into the tunnel)"
	docker exec br-site ip route replace 1.1.1.1/32 via 10.255.1.1 dev br0
	docker exec br-site ping -c 3 -W 2 1.1.1.1 | tail -2
	echo "== hub must not forward site -> other tunnels / non-eth0"
	docker exec br-hub nft list table inet br
	echo "== health"; docker inspect -f '{{.State.Health.Status}}' br-hub
}

down() {
	docker rm -f br-site br-hub >/dev/null 2>&1 || true
	for i in 1 2 3; do ip link del brlab$i 2>/dev/null || true; done
	for n in br-lane1 br-lane2 br-lane3 br-hubnet; do docker network rm $n >/dev/null 2>&1 || true; done
	rm -rf $W
}

case "${1:-}" in up) up ;; test) t ;; down) down ;; *) sed -n 2,8p "$0"; exit 2 ;; esac
