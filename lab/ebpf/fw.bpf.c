// SPDX-License-Identifier: GPL-2.0
// Toy stateful "Cloud Firewall" in eBPF, shaped like what hcnet is described to do.
// NOT Hetzner's code. Used by lab/ebpf/run.sh to test the claims in docs/ebpf.md.
//
// Attach point: the host-side end of a VM's virtual NIC (here a veth called "host0").
//   from_vm  -> tcx ingress on host0 (packets the VM sends)
//   to_vm    -> tcx egress  on host0 (packets going into the VM)
//
// State: one connection table per address family (ct4, ct6), each with a hard
// max_entries. When a table is full the behaviour depends on cfg.mode:
//   MODE_HCNET    = skip tracking, decide by rules only (hcnet's documented fallback)
//   MODE_STANDARD = drop the new connection (what the OVS stack does)
#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/ipv6.h>
#include <linux/in.h>
#include <linux/tcp.h>
#include <linux/udp.h>
#include <linux/pkt_cls.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>

#ifndef CT_MAX
#define CT_MAX 1000
#endif
#define E2BIG_ 7
#define ENOMEM_ 12

#define TCP_FIN 0x01
#define TCP_SYN 0x02
#define TCP_RST 0x04
#define TCP_ACK 0x10

enum { MODE_HCNET = 0, MODE_STANDARD = 1 };
enum { DIR_FROM_VM = 1, DIR_TO_VM = 2 };
enum {
	ST_HIT,           // packet matched a tracked connection
	ST_NEW,           // new connection added to the table
	ST_FULL_FALLBACK, // table full, passed on rules only (hcnet)
	ST_FULL_DROP,     // table full, dropped (standard)
	ST_NORULE_DROP,   // inbound, untracked, no rule allows it
	ST_STATELESS_OK,  // inbound non-SYN allowed by a rule without tracking
	ST_CLOSED,        // entry removed after FIN in both directions or RST
	ST_MAX
};

struct ct_key {
	__u32 vm[4];     // VM address (IPv4 uses vm[0])
	__u32 peer[4];   // remote address
	__u16 vm_port;   // network byte order
	__u16 peer_port; // network byte order
	__u8 proto;
	__u8 pad[3];
};

struct ct_val {
	__u64 created_ns;
	__u64 last_seen_ns;
	__u64 packets;
	__u32 fin_seen; // bitmask of DIR_* that sent a FIN
	__u32 pad;
};

struct config {
	__u32 mode;
	__u32 allow_all; // 1 = every inbound packet matches a rule
};

struct rule_key {
	__u8 proto;
	__u8 pad;
	__u16 port; // network byte order
};

struct {
	__uint(type, BPF_MAP_TYPE_HASH);
	__uint(max_entries, CT_MAX);
	__type(key, struct ct_key);
	__type(value, struct ct_val);
} ct4 SEC(".maps");

struct {
	__uint(type, BPF_MAP_TYPE_HASH);
	__uint(max_entries, CT_MAX);
	__type(key, struct ct_key);
	__type(value, struct ct_val);
} ct6 SEC(".maps");

struct {
	__uint(type, BPF_MAP_TYPE_ARRAY);
	__uint(max_entries, 1);
	__type(key, __u32);
	__type(value, struct config);
} cfg SEC(".maps");

struct {
	__uint(type, BPF_MAP_TYPE_HASH);
	__uint(max_entries, 64);
	__type(key, struct rule_key);
	__type(value, __u8);
} rules SEC(".maps");

struct {
	__uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
	__uint(max_entries, ST_MAX);
	__type(key, __u32);
	__type(value, __u64);
} stats SEC(".maps");

static __always_inline void count(__u32 idx)
{
	__u64 *c = bpf_map_lookup_elem(&stats, &idx);
	if (c)
		*c += 1;
}

struct pkt {
	struct ct_key k;
	int v6;
	int use_ct6; // hcnet: IPv6 has its own table. standard: one shared table.
	__u8 flags; // TCP flags, 0 for UDP
};

// Parse Ethernet + IPv4/IPv6 + TCP/UDP. Returns 0 if the packet should be
// filtered, -1 if it isn't TCP/UDP (passed through untouched).
static __always_inline int parse(struct __sk_buff *skb, int dir, struct pkt *p)
{
	void *data = (void *)(long)skb->data;
	void *end = (void *)(long)skb->data_end;
	struct ethhdr *eth = data;
	void *l4;
	__u8 proto;

	if ((void *)(eth + 1) > end) // every access needs a bounds check, or the verifier refuses to load
		return -1;

	if (eth->h_proto == bpf_htons(ETH_P_IP)) {
		struct iphdr *ip = (void *)(eth + 1);
		if ((void *)(ip + 1) > end)
			return -1;
		proto = ip->protocol;
		l4 = (void *)ip + ip->ihl * 4;
		if (dir == DIR_FROM_VM) {
			p->k.vm[0] = ip->saddr;
			p->k.peer[0] = ip->daddr;
		} else {
			p->k.vm[0] = ip->daddr;
			p->k.peer[0] = ip->saddr;
		}
	} else if (eth->h_proto == bpf_htons(ETH_P_IPV6)) {
		struct ipv6hdr *ip6 = (void *)(eth + 1);
		if ((void *)(ip6 + 1) > end)
			return -1;
		proto = ip6->nexthdr; // toy: no extension headers
		l4 = ip6 + 1;
		p->v6 = 1;
		if (dir == DIR_FROM_VM) {
			__builtin_memcpy(p->k.vm, &ip6->saddr, 16);
			__builtin_memcpy(p->k.peer, &ip6->daddr, 16);
		} else {
			__builtin_memcpy(p->k.vm, &ip6->daddr, 16);
			__builtin_memcpy(p->k.peer, &ip6->saddr, 16);
		}
	} else {
		return -1;
	}

	if (proto == IPPROTO_TCP) {
		struct tcphdr *tcp = l4;
		if ((void *)(tcp + 1) > end)
			return -1;
		p->flags = ((__u8 *)tcp)[13];
		p->k.vm_port = dir == DIR_FROM_VM ? tcp->source : tcp->dest;
		p->k.peer_port = dir == DIR_FROM_VM ? tcp->dest : tcp->source;
	} else if (proto == IPPROTO_UDP) {
		struct udphdr *udp = l4;
		if ((void *)(udp + 1) > end)
			return -1;
		p->k.vm_port = dir == DIR_FROM_VM ? udp->source : udp->dest;
		p->k.peer_port = dir == DIR_FROM_VM ? udp->dest : udp->source;
	} else {
		return -1;
	}
	p->k.proto = proto;
	return 0;
}

static __always_inline struct ct_val *ct_lookup(struct pkt *p)
{
	return p->use_ct6 ? bpf_map_lookup_elem(&ct6, &p->k) : bpf_map_lookup_elem(&ct4, &p->k);
}

static __always_inline long ct_insert(struct pkt *p, struct ct_val *v)
{
	return p->use_ct6 ? bpf_map_update_elem(&ct6, &p->k, v, BPF_NOEXIST)
		     : bpf_map_update_elem(&ct4, &p->k, v, BPF_NOEXIST);
}

static __always_inline void ct_delete(struct pkt *p)
{
	if (p->use_ct6)
		bpf_map_delete_elem(&ct6, &p->k);
	else
		bpf_map_delete_elem(&ct4, &p->k);
}

// Packet belongs to a tracked connection: refresh it, and forget it once both
// sides have sent FIN, or on RST.
static __always_inline int ct_hit(struct pkt *p, struct ct_val *v, int dir)
{
	count(ST_HIT);
	v->last_seen_ns = bpf_ktime_get_ns();
	v->packets++;
	if (p->flags & TCP_FIN)
		v->fin_seen |= dir;
	if ((p->flags & TCP_RST) || v->fin_seen == (DIR_FROM_VM | DIR_TO_VM)) {
		ct_delete(p);
		count(ST_CLOSED);
	}
	return TC_ACT_OK;
}

// Try to add a new connection. What happens when the table is full is the
// whole difference between the two stacks.
static __always_inline int ct_new(struct pkt *p, struct config *c)
{
	__u64 now = bpf_ktime_get_ns();
	struct ct_val v = { .created_ns = now, .last_seen_ns = now, .packets = 1 };
	long err = ct_insert(p, &v);

	if (err == 0) {
		count(ST_NEW);
		return TC_ACT_OK;
	}
	if (err == -E2BIG_ || err == -ENOMEM_) { // table full (kernel/bpf/hashtab.c)
		if (c->mode == MODE_STANDARD) {
			count(ST_FULL_DROP);
			return TC_ACT_SHOT;
		}
		count(ST_FULL_FALLBACK);
		return TC_ACT_OK; // rules already allowed it; just don't track it
	}
	return TC_ACT_OK; // -EEXIST: raced with another CPU, fine
}

static __always_inline int is_new_tcp(struct pkt *p)
{
	return p->k.proto != IPPROTO_TCP ||
	       ((p->flags & TCP_SYN) && !(p->flags & (TCP_ACK | TCP_RST | TCP_FIN)));
}

static __always_inline struct config *get_cfg(void)
{
	__u32 zero = 0;
	return bpf_map_lookup_elem(&cfg, &zero);
}

// VM -> world. Cloud Firewalls allow all outbound by default, so the only
// question is whether we can remember the connection for its replies.
SEC("tc")
int from_vm(struct __sk_buff *skb)
{
	struct pkt p = {};
	struct config *c = get_cfg();
	struct ct_val *v;

	if (!c || parse(skb, DIR_FROM_VM, &p))
		return TC_ACT_OK;
	p.use_ct6 = p.v6 && c->mode == MODE_HCNET;
	v = ct_lookup(&p);
	if (v)
		return ct_hit(&p, v, DIR_FROM_VM);
	if (!is_new_tcp(&p))
		return TC_ACT_OK; // e.g. the last ACK of a closed connection
	return ct_new(&p, c);
}

// World -> VM. Tracked replies pass; anything else needs an inbound rule.
SEC("tc")
int to_vm(struct __sk_buff *skb)
{
	struct pkt p = {};
	struct config *c = get_cfg();
	struct ct_val *v;
	struct rule_key rk = {};

	if (!c || parse(skb, DIR_TO_VM, &p))
		return TC_ACT_OK;
	p.use_ct6 = p.v6 && c->mode == MODE_HCNET;
	v = ct_lookup(&p);
	if (v)
		return ct_hit(&p, v, DIR_TO_VM);

	rk.proto = p.k.proto;
	rk.port = p.k.vm_port;
	if (!c->allow_all && !bpf_map_lookup_elem(&rules, &rk)) {
		count(ST_NORULE_DROP);
		return TC_ACT_SHOT;
	}
	if (!is_new_tcp(&p)) {
		count(ST_STATELESS_OK);
		return TC_ACT_OK;
	}
	return ct_new(&p, c);
}

char LICENSE[] SEC("license") = "GPL";
