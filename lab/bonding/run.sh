#!/bin/bash
# Verifies the claims and commands in docs/bonding.md inside a privileged container.
#
# Run from the repo root (Docker Desktop or any Linux Docker host):
#   docker run --rm --privileged -v "$PWD/lab/bonding:/lab" ubuntu:24.04 bash -c '
#     export DEBIAN_FRONTEND=noninteractive
#     apt-get update -qq && apt-get install -y -qq iproute2 iputils-ping tcpdump conntrack \
#       nftables iperf3 netcat-openbsd curl python3 clang llvm linux-libc-dev >/dev/null
#     bash /lab/run.sh'
#
# --privileged is needed to create network namespaces, bonds and XDP programs.
# Everything happens inside the container's own namespaces; the host network is untouched.
set -u
sudo() { "$@"; }              # docs use sudo; container runs as root
hdr() { echo; echo "=================== $* ==================="; }
L() { ip netns exec left "$@"; }
R() { ip netns exec right "$@"; }

hdr "kernel"
uname -r

hdr "T1: namespace lab from the docs (verbatim, sudo = no-op)"
sudo ip netns add left
sudo ip netns add right
sudo ip link add l0 netns left type veth peer name r0 netns right
sudo ip link add l1 netns left type veth peer name r1 netns right
for side in left right; do
  sudo ip -n $side link add bond0 type bond mode 802.3ad miimon 100 lacp_rate fast xmit_hash_policy layer3+4
done
sudo ip -n left  link set l0 down; sudo ip -n left  link set l0 master bond0
sudo ip -n left  link set l1 down; sudo ip -n left  link set l1 master bond0
sudo ip -n right link set r0 down; sudo ip -n right link set r0 master bond0
sudo ip -n right link set r1 down; sudo ip -n right link set r1 master bond0
sudo ip -n left  addr add 192.0.2.1/24 dev bond0
sudo ip -n right addr add 192.0.2.2/24 dev bond0
for side in left right; do sudo ip -n $side link set bond0 up; done
# NOTE: the doc never sets the veth ports up explicitly; check whether enslaving does it
ip -n left -br link show
sleep 4   # let LACP converge (fast rate = 1s LACPDUs)
sudo ip netns exec left ping -c3 -W1 192.0.2.2; echo "ping rc=$?"

hdr "T2: /proc/net/bonding/bond0 (Aggregator IDs must match)"
L cat /proc/net/bonding/bond0 | grep -E "Bonding Mode|Transmit Hash|LACP rate|LACP active|Slave Interface|MII Status|Aggregator ID|Speed"

hdr "T3: ip link xstats type bond (known to crash with iproute2 6.1 and 6.15 on kernel 7.0)"
L ip link xstats type bond dev bond0 2>&1 | head -30; echo "rc=${PIPESTATUS[0]}"

hdr "T4: LACPDUs visible on port, not on bond0"
L timeout 3 tcpdump -ni l0 -c2 ether proto 0x8809 2>&1 | tail -3
L timeout 3 tcpdump -ni bond0 -c2 ether proto 0x8809 2>&1 | tail -3

hdr "T5: hashing - 1 flow stays on one port, 8 flows spread (layer3+4)"
R iperf3 -s -D -1 >/dev/null 2>&1; sleep 1
txb() { L cat /sys/class/net/$1/statistics/tx_bytes; }
a0=$(txb l0); a1=$(txb l1)
L iperf3 -c 192.0.2.2 -t 3 -P 1 >/dev/null 2>&1
b0=$(txb l0); b1=$(txb l1)
echo "1 flow : l0 +$(( (b0-a0)/1000000 )) MB, l1 +$(( (b1-a1)/1000000 )) MB"
R iperf3 -s -D -1 >/dev/null 2>&1; sleep 1
a0=$(txb l0); a1=$(txb l1)
L iperf3 -c 192.0.2.2 -t 3 -P 8 >/dev/null 2>&1
b0=$(txb l0); b1=$(txb l1)
echo "8 flows: l0 +$(( (b0-a0)/1000000 )) MB, l1 +$(( (b1-a1)/1000000 )) MB"

hdr "T6: conntrack entry has no interface"
R nft add table inet t
R nft add chain inet t in '{ type filter hook input priority 0; }'
R nft add rule inet t in ct state established,related accept
R sh -c 'nc -l -p 2222 >/dev/null &'; sleep 0.5
L sh -c 'echo hi | nc -w1 192.0.2.2 2222'
R conntrack -L -p tcp --dport 2222 2>/dev/null

hdr "T7: tcpdump sees the same traffic on port and on bond (two rx passes)"
L sh -c 'ping -c6 -i0.2 192.0.2.2 >/dev/null &'
R timeout 2 tcpdump -ni bond0 -c2 icmp 2>&1 | grep -c "ICMP echo request" | sed 's/^/on bond0: /'
R sh -c 'ping -c6 -i0.2 192.0.2.1 >/dev/null &'
R timeout 2 tcpdump -ni any -c4 icmp 2>&1 | grep -E "r0|r1|bond0" | awk '{print $2}' | sort | uniq -c

hdr "T8: failover - pull one cable"
sudo ip -n left link set l0 down
sleep 1
sudo ip netns exec left ping -c3 -W1 192.0.2.2; echo "ping rc=$?"
L cat /proc/net/bonding/bond0 | grep -E "Slave Interface|MII Status"
sudo ip -n left link set l0 up; sleep 3

hdr "T9: ss commands from conntrack-in-practice.md"
R sh -c 'nc -lk -p 3333 >/dev/null &'; sleep 0.3
L sh -c 'sleep 5 | nc 192.0.2.2 3333 &'; sleep 0.5
echo "ss -Htn4 state established | wc -l  -> $(L ss -Htn4 state established | wc -l)"
echo "raw line:"; L ss -Htn state established | head -2
echo "peer column (\$4):"; L ss -Htn state established | awk '{print $4}' | sed 's/:[0-9]*$//' | sort | uniq -c

hdr "T10: XDP on bond0 propagates to ports"
cat > /tmp/xdp_pass.c <<'EOF'
#include <linux/bpf.h>
#define SEC(n) __attribute__((section(n), used))
SEC("xdp") int xdp_pass(struct xdp_md *ctx) { return XDP_PASS; }
char _license[] SEC("license") = "GPL";
EOF
clang -O2 -g -target bpf -I/usr/include/$(uname -m)-linux-gnu -c /tmp/xdp_pass.c -o /tmp/xdp_pass.o && echo compiled
L ip link set dev bond0 xdpdrv obj /tmp/xdp_pass.o sec xdp; echo "attach to bond0 rc=$?"
echo "bond0: $(L ip link show bond0 | grep -o 'prog/xdp id [0-9]*' || echo 'no prog shown')"
echo "l0:    $(L ip link show l0 | grep -o 'prog/xdp id [0-9]*' || echo 'no prog shown')"
echo "l1:    $(L ip link show l1 | grep -o 'prog/xdp id [0-9]*' || echo 'no prog shown')"
sudo ip netns exec left ping -c2 -W1 192.0.2.2 >/dev/null; echo "ping with XDP_PASS rc=$?"
L ip link set dev bond0 xdpdrv off

hdr "T10b: XDP_DROP on the peer's bond0 really runs on its ports"
sed 's/XDP_PASS/XDP_DROP/; s/xdp_pass/xdp_drop/' /tmp/xdp_pass.c > /tmp/xdp_drop.c
clang -O2 -g -target bpf -I/usr/include/$(uname -m)-linux-gnu -c /tmp/xdp_drop.c -o /tmp/xdp_drop.o
R ip link set dev bond0 xdpdrv obj /tmp/xdp_drop.o sec xdp; echo "attach DROP to right bond0 rc=$?"
L ping -c3 -W1 192.0.2.2 >/dev/null; echo "ping rc=$? (expect 1: dropped by XDP on r0/r1)"
R ip link set dev bond0 xdpdrv off
L ping -c2 -W1 192.0.2.2 >/dev/null; echo "after detach ping rc=$? (expect 0)"

hdr "T11: XDP refused when a port already has its own program"
L ip link set dev l0 nomaster
L ip link set dev l0 xdpdrv obj /tmp/xdp_pass.o sec xdp; echo "xdp on l0 rc=$?"
L ip link set dev l0 down
L ip link set dev l0 master bond0; echo "enslave l0 (has prog) rc=$?"
L ip link set dev bond0 xdpdrv obj /tmp/xdp_pass.o sec xdp 2>&1; echo "attach bond0 rc=$?"
L ip link set dev l0 xdpdrv off 2>/dev/null

hdr "T12: XDP refused in unsupported mode (balance-alb)"
ip netns add m; ip -n m link add b1 type bond mode balance-alb
ip -n m link add v0 type veth peer name v1; ip -n m link set v0 master b1
ip -n m link set dev b1 xdpdrv obj /tmp/xdp_pass.o sec xdp 2>&1; echo "rc=$?"

hdr "T13: IPv6 link-local zone ID in curl (%25)"
ip -n right -6 addr add fe80::a9fe:a9fe/64 dev bond0 nodad
R sh -c 'cd /tmp && python3 -m http.server --bind fe80::a9fe:a9fe%bond0 8080 >/dev/null 2>&1 &'
sleep 1.5
L curl -s -m3 -o /dev/null -w 'curl %%25 form: HTTP %{http_code}\n' 'http://[fe80::a9fe:a9fe%25bond0]:8080/'
L curl -s -m3 -g -o /dev/null -w 'curl -g raw %% form: HTTP %{http_code}\n' 'http://[fe80::a9fe:a9fe%bond0]:8080/'

hdr "T14: bond0 has no queue"
L ip link show bond0 | grep -o "qdisc [a-z_]*"

hdr "done"
