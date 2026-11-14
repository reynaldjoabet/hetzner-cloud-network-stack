#!/bin/bash
# Verifies the claims in docs/ebpf.md with a toy eBPF firewall (fw.bpf.c).
#
# Run from the repo root (Docker Desktop or any Linux Docker host):
#   docker run --rm --privileged -v "$PWD/lab/ebpf:/lab" debian:trixie bash -c '
#     export DEBIAN_FRONTEND=noninteractive
#     apt-get update -qq && apt-get install -y -qq --no-install-recommends \
#       clang llvm libbpf-dev bpftool iproute2 python3 libc6-dev >/dev/null
#     bash /lab/run.sh'
#
# --privileged is needed to load BPF programs and create network namespaces.
# Everything happens inside the container; the host network is untouched.
#
# Topology (the container's own namespace plays "the host"):
#
#   client side (container netns)          "VM" (netns vm)
#   10.0.0.1  fd00::1                      10.0.0.2  fd00::2
#        host0 ───────── veth ───────────── vm0
#          ▲ tcx ingress: from_vm   (packets the VM sends)
#          ▲ tcx egress:  to_vm     (packets going into the VM)
#
# The toy tables hold 1,000 entries (CT_MAX) instead of 120,000 so they fill quickly.
set -u
LAB=$(cd "$(dirname "$0")" && pwd)
B=/sys/fs/bpf/fw
M=$B/maps
VM() { ip netns exec vm "$@"; }
hdr() { echo; echo "=================== $* ==================="; }
conn() { python3 "$LAB/conn.py" "$@"; }

ct_count() { bpftool map dump pinned "$M/$1" -j | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))'; }
tables() { echo "entries: ct4=$(ct_count ct4) ct6=$(ct_count ct6)"; }
stats() {
  bpftool map dump pinned "$M/stats" -j | python3 -c '
import json, sys
names = ["hit", "new", "full_fallback", "full_drop", "norule_drop", "stateless_ok", "closed"]
out = []
for e in json.load(sys.stdin):
    f = e.get("formatted", e)
    total = sum(v["value"] for v in f["values"])
    name = names[f["key"]]
    if total:
        out.append(f"{name}={total}")
print("stats:", " ".join(out) or "(none)")'
}
reset_stats() { for i in 0 1 2 3 4 5 6; do bpftool map update pinned "$M/stats" key $i 0 0 0 value 0 0 0 0 0 0 0 0 2>/dev/null; done; }
# mode: 0 = hcnet (fallback to rules), 1 = standard (drop, one shared table)
set_cfg() { bpftool map update pinned "$M/cfg" key 0 0 0 0 value "$1" 0 0 0 "$2" 0 0 0; echo "config: mode=$([ "$1" = 0 ] && echo hcnet || echo standard) allow_all=$2"; }
flush_ct() { for t in ct4 ct6; do bpftool map dump pinned "$M/$t" -j | python3 -c '
import json, sys, subprocess
for e in json.load(sys.stdin):
    subprocess.run(["bpftool", "map", "delete", "pinned", sys.argv[1], "key", "hex"] + [k[2:] for k in e["key"]], check=True)' "$M/$t"; done; }
start_hold() {  # start_hold HOST PORT N -> holds connections in the background
  rm -f /tmp/hold.out
  python3 "$LAB/conn.py" hold "$1" "$2" "$3" >/tmp/hold.out 2>&1 &
  HOLD=$!
  until [ -s /tmp/hold.out ]; do sleep 0.2; done
  cat /tmp/hold.out
}
stop_hold() { kill "$HOLD" 2>/dev/null; wait "$HOLD" 2>/dev/null; }

ulimit -n 65536
trap 'kill $(jobs -p) 2>/dev/null' EXIT
mountpoint -q /sys/fs/bpf || mount -t bpf bpf /sys/fs/bpf

hdr "kernel and tools"
uname -r
bpftool version | head -1
clang --version | head -1

hdr "T1: the verifier rejects unsafe programs"
cd "$LAB"
INC=/usr/include/$(uname -m)-linux-gnu
clang -O2 -g -target bpf -I"$INC" -DBAD_BOUNDS -c bad.bpf.c -o /tmp/bad_bounds.o
clang -O2 -g -target bpf -I"$INC" -DBAD_LOOP   -c bad.bpf.c -o /tmp/bad_loop.o
echo "--- reading the IP header without a bounds check:"
bpftool prog load /tmp/bad_bounds.o /sys/fs/bpf/bad 2>&1 | grep -E "invalid access|outside|failed to load:"
echo "--- a loop that may never end:"
bpftool prog load /tmp/bad_loop.o /sys/fs/bpf/bad 2>&1 | grep -E "infinite loop|failed to load:"

hdr "T2: compile, verify, JIT and attach the toy firewall"
clang -O2 -g -target bpf -I"$INC" -c fw.bpf.c -o /tmp/fw.o
llvm-objdump -h /tmp/fw.o | grep -E " tc |\.maps|license"
bpftool prog loadall /tmp/fw.o $B pinmaps $M
for p in from_vm to_vm; do bpftool prog show pinned $B/$p | head -3; done
echo "--- JIT config of this kernel:"
(zcat /proc/config.gz 2>/dev/null || true) | grep -E "^CONFIG_BPF_JIT(_ALWAYS_ON)?="
echo "--- verified program as the kernel rewrote it (excerpt):"
bpftool prog dump xlated pinned $B/to_vm | sed -n '/r1 = map\[id/,/goto pc+1/p' | head -7
bpftool prog dump xlated pinned $B/to_vm | grep -E "skb->data;" -A1 | head -2
bpftool prog dump xlated pinned $B/to_vm | grep -oE "call [a-z_]+" | sort | uniq -c

ip netns add vm
ip link add host0 type veth peer name vm0 netns vm
ip addr add 10.0.0.1/24 dev host0; ip addr add fd00::1/64 dev host0 nodad
VM ip addr add 10.0.0.2/24 dev vm0; VM ip addr add fd00::2/64 dev vm0 nodad
ip link set host0 up; VM ip link set vm0 up; VM ip link set lo up
bpftool net attach tcx_ingress pinned $B/from_vm dev host0
bpftool net attach tcx_egress  pinned $B/to_vm   dev host0
bpftool net show dev host0 | sed -n '/tc:/,$p'

# Firewall rules: allow inbound TCP 8080 only. Port is in network byte order (8080 = 0x1f90).
bpftool map update pinned $M/rules key 6 0 0x1f 0x90 value 1
set_cfg 0 0
VM python3 "$LAB/conn.py" serve 8080 2>/tmp/serve8080.log & sleep 0.3   # allowed by a rule
VM python3 "$LAB/conn.py" serve 9090 2>/tmp/serve9090.log & sleep 0.3   # no rule
python3 "$LAB/conn.py" serve 7000 2>/tmp/serve7000.log & sleep 0.5      # a server "out on the internet"

hdr "T3: stateful basics (rule = allow tcp/8080 in)"
conn probe 10.0.0.2 8080 3
conn probe 10.0.0.2 9090 2
echo "--- the VM connects out (no inbound rule needed for the replies):"
VM python3 "$LAB/conn.py" probe 10.0.0.1 7000 3
sleep 0.5; tables; stats
echo "--- one tracked entry while a connection is open:"
start_hold 10.0.0.2 8080 1
bpftool map dump pinned $M/ct4 | sed -n '/"value"/,$p' | head -8
stop_hold; sleep 0.5; tables

hdr "T4: hcnet mode, fill the IPv4 table (1,000) with 1,100 connections"
reset_stats
start_hold 10.0.0.2 8080 1100
tables; stats
echo "--- new inbound IPv4 to a port with a rule (like SSH):"
conn probe 10.0.0.2 8080 3
echo "--- the VM connects out over IPv4 (replies need a table entry):"
VM python3 "$LAB/conn.py" probe 10.0.0.1 7000 2
echo "--- IPv6 has its own table:"
conn probe fd00::2 8080 3
VM python3 "$LAB/conn.py" probe fd00::1 7000 3
stats

hdr "T5: recovery when the connections close"
stop_hold
for t in 0 0.1 0.5 1; do sleep $t; echo "after +${t}s: $(tables)"; done
VM python3 "$LAB/conn.py" probe 10.0.0.1 7000 3

hdr "T6: standard mode, one shared table, drop when full"
flush_ct; set_cfg 1 0; reset_stats
start_hold 10.0.0.2 8080 1100
tables; stats
echo "--- new inbound IPv4, IPv6 (shared pool) and outbound:"
conn probe 10.0.0.2 8080 2
conn probe fd00::2 8080 2
VM python3 "$LAB/conn.py" probe 10.0.0.1 7000 2
stop_hold; sleep 1; tables

hdr "T7: allow-all firewall, 1,300 connections"
flush_ct
for mode in 0 1; do
  set_cfg $mode 1; reset_stats
  start_hold 10.0.0.2 9090 1300
  tables; stats
  stop_hold; sleep 1; flush_ct
done

hdr "T8: cost per packet"
set_cfg 0 0; reset_stats
echo 1 >/proc/sys/kernel/bpf_stats_enabled
conn probe 10.0.0.2 8080 500
for p in from_vm to_vm; do
  bpftool prog show pinned $B/$p -j | python3 -c '
import json, sys
p = json.load(sys.stdin)
n, ns = p.get("run_cnt", 0), p.get("run_time_ns", 0)
name = p["name"]
print(f"{name:8} runs={n}  total={ns} ns  average={ns / max(n, 1):.0f} ns per packet")'
done
echo 0 >/proc/sys/kernel/bpf_stats_enabled

hdr "T9: detach"
bpftool net detach tcx_ingress dev host0
bpftool net detach tcx_egress dev host0
conn probe 10.0.0.2 9090 2
echo done
