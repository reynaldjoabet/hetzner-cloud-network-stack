// SPDX-License-Identifier: GPL-2.0
// Deliberately broken: reads the IP header without checking that the packet is
// long enough. The verifier must refuse to load this.
#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/in.h>
#include <linux/pkt_cls.h>
#include <bpf/bpf_helpers.h>

#ifdef BAD_BOUNDS
SEC("tc")
int no_bounds_check(struct __sk_buff *skb)
{
	struct ethhdr *eth = (void *)(long)skb->data;
	struct iphdr *ip = (void *)(eth + 1);

	if (ip->protocol == IPPROTO_TCP) // out-of-bounds read if the packet is short
		return TC_ACT_SHOT;
	return TC_ACT_OK;
}
#endif

#ifdef BAD_LOOP
// Deliberately broken: a loop the verifier can't prove ends.
SEC("tc")
int endless(struct __sk_buff *skb)
{
	volatile int i = 0;
	while (skb->len > 0)
		i++;
	return TC_ACT_OK;
}
#endif

char LICENSE[] SEC("license") = "GPL";
