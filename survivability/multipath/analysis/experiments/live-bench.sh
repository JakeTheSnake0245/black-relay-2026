# shared helpers for the throughput tests (br-edge). Shares always follow the sliders (br0.conf UPLINKS).
GT=/usr/lib/black-relay/glorytun; L=${L:-6}
lanes() { i=$1; j=0; while [ $j -lt $L ]; do echo "127.0.1.$((i * L + j + 1))"; j=$((j + 1)); done; }
setlane() { $GT path dev br0 addr 127.0.0.1 to addr $1 port 5001 set rate fixed tx $2 rx $3 >/dev/null 2>&1; }
caps() { . /etc/black-relay/br0.conf; echo "$UPLINKS"; }
restore() { i=0; for spec in $(caps); do m=${spec#*:}; tx=${m%/*}; rx=${m#*/}
  for a in $(lanes $i); do setlane $a $((tx * 125000 / L)) $((rx * 125000 / L)); done; i=$((i + 1)); done; }
# scale TOTAL_UP TOTAL_DOWN (Mbit): every uplink keeps its slider share, the total is set
scale() { tu=$1; td=$2; st=0; sr=0; i=0
  for spec in $(caps); do ifc=${spec%%:*}; m=${spec#*:}
    if ip -4 addr show dev $ifc | grep -q inet; then st=$((st + ${m%/*})); sr=$((sr + ${m#*/})); fi; done
  for spec in $(caps); do ifc=${spec%%:*}; m=${spec#*:}; tx=${m%/*}; rx=${m#*/}
    for a in $(lanes $i); do setlane $a $((tu * 125000 * tx / st / L)) $((td * 125000 * rx / sr / L)); done; i=$((i + 1)); done; }
# bench LABEL: 4 flows 20 s download, then 1 flow 15 s; useful Mbit, tunnel Mbit, waste, rtt under load
bench() {
  b0=$(cat /sys/class/net/br0/statistics/rx_bytes)
  ( sleep 10; ping -c5 -i0.5 -W2 -I br0 10.255.1.1 | awk -F/ '/rtt/{print $5}' > /tmp/brb.rtt ) & pp=$!
  g=$(for k in 1 2 3 4; do curl -4 -s -o /dev/null --max-time 20 -w "%{size_download}\n" https://hel1-speed.hetzner.com/1GB.bin & done; wait)
  b1=$(cat /sys/class/net/br0/statistics/rx_bytes); wait $pp
  g1=$(curl -4 -s -o /dev/null --max-time 15 -w "%{size_download}" https://hel1-speed.hetzner.com/1GB.bin)
  echo "$g" | awk -v l="$1" -v t=$((b1 - b0)) -v g1="$g1" -v r="$(cat /tmp/brb.rtt 2>/dev/null)" '{s+=$1} END {
    printf "%-38s 4 flows %5.1f | 1 flow %5.1f Mbit/s | tunnel %5.1f | waste %3.0f%% | rtt %s ms\n", l, s*8/20e6, g1*8/15e6, t*8/20e6, (t>0 ? (1-s/t)*100 : 0), r }'
}
