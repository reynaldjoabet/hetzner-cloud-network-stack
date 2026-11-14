# Switching a server to hcnet

A step-by-step runbook for moving one server to hcnet, checking it, and rolling it back if needed.

- [Before you start](#before-you-start)
- [1. Record a baseline](#1-record-a-baseline)
- [2. Switch](#2-switch)
- [3. Refresh DHCP](#3-refresh-dhcp)
- [4. Verify](#4-verify)
- [5. Watch for a while](#5-watch-for-a-while)
- [Rolling back](#rolling-back)
- [Troubleshooting](#troubleshooting)
- [Rolling out to a fleet](#rolling-out-to-a-fleet)

---

## Before you start

- **Expect a short outage.** Both switching and rolling back briefly interrupt connectivity. With a Cloud Firewall attached, existing connections (SSH sessions, WebSockets, DB connections) may drop.
- **Have a way back in.** Keep the Hetzner Console open. The web console (VNC) works without the network, so you can still reach the server if networking misbehaves.
- **Pick the right server first.** Start with one that is behind a load balancer, or one whose short outage nobody will notice.
- **It's a beta.** Hetzner asks for feedback through the **Provide Feedback** button in the server's *Networking* tab.
- **Check the throughput tradeoff.** If the server receives a lot of plain TCP traffic (more than about 10 Gbit/s on CCX, or 4 Gbit/s on CPX), hcnet may roughly halve it. Benchmark it first. See [benchmarks](benchmarks.md#should-you-switch).

## 1. Record a baseline

Run these on the server and save the output, so you can compare after the switch:

```bash
mkdir -p ~/hcnet-check && cd ~/hcnet-check
ip -br addr                      > addr.before
ip route                         > route4.before
ip -6 route                      > route6.before
ip route get 169.254.169.254     > metadata-route.before
ss -s                            > sockets.before
ip -s link show eth0             > eth0-counters.before
ethtool -k eth0 2>/dev/null | grep -E 'generic-receive|tcp-segmentation|checksum' > offloads.before
curl -s -m 3 http://169.254.169.254/hetzner/v1/metadata/instance-id; echo
```

The last line should print your server's numeric ID. If it doesn't, fix that *before* switching.

Interface names vary by image: the public one is usually `eth0`, and private ones `ens10`, `ens11` or `enp7s0`. Adjust the commands to match yours.

## 2. Switch

Hetzner Console → your project → **Servers** → select the server → **Networking** tab → **Network Stack** → **Try new network stack**.

There is no API or `hcloud` CLI command for this yet.

## 3. Refresh DHCP

Hetzner can't make your server renew its DHCP lease when you switch, so the new metadata routes that hcnet hands out only appear on the next renewal. Renew now instead of waiting.

**Ubuntu / Debian with netplan or systemd-networkd** (most Hetzner images):

```bash
sudo networkctl renew eth0
sudo networkctl renew ens10      # each private interface, if any
```

**NetworkManager** (Fedora, Rocky, Alma):

```bash
sudo nmcli device reapply eth0
```

**Classic `dhclient`:**

```bash
sudo dhclient -r eth0 && sudo dhclient eth0   # drops the connection for a moment; run it from the web console
```

**Simplest:** `sudo reboot`. A reboot always picks up the new routes.

## 4. Verify

**Connectivity:**

```bash
ping -c3 1.1.1.1
ping -6 -c3 2606:4700:4700::1111
curl -sS -m 5 -o /dev/null -w '%{http_code}\n' https://example.com
```

**Metadata over IPv4 and IPv6:**

```console
$ curl -s -m 3 http://169.254.169.254/hetzner/v1/metadata/hostname
web-1
$ curl -s -m 3 'http://[fe80::a9fe:a9fe%25eth0]/hetzner/v1/metadata/hostname'
web-1
```

The IPv6 address only works on hcnet, so it is a quick way to confirm the switch took effect.

**Routes:**

```bash
diff route4.before <(ip route)
ip route get 169.254.169.254
```

Depending on your DHCP client, you may now see an explicit route to `169.254.169.254` for each interface. Some clients receive the routes but don't show them all.

**Private network** (if attached):

```bash
ping -c3 10.0.0.3                       # another server on the same network
ip link show ens10 | grep -o 'mtu [0-9]*'   # should still be 1450
```

**Your services**, from outside the server:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://your-domain.example
nc -vz 203.0.113.7 22
```

**Firewall still blocking what it should**, again from outside:

```bash
nc -vz -w 3 203.0.113.7 3306    # a port with no rule: should time out
```

## 5. Watch for a while

Compare packet counters. On hcnet, incoming packets aren't merged on the host, so the packet rate for the same traffic can go up:

```bash
ip -s link show eth0
```

Some monitoring dashboards alert on packets per second. Don't mistake this for a traffic increase: compare bytes, not packets. Expect 8–20× more packets for bulk TCP.

Watch the receiving vCPU during your busiest period:

```bash
mpstat -P ALL 5     # one vCPU near 100% %soft = receive bottleneck
```

If one vCPU is saturated, enable RPS (see [tuning a server on hcnet](benchmarks.md#tuning-a-server-on-hcnet)), or roll back if throughput matters more than the other benefits.

Quick sanity checks that you are on hcnet:

```console
$ ping -c3 172.31.1.1          # gateway: ~0.1 ms on hcnet, ~1.3 ms on standard
$ traceroute -n 1.1.1.1        # one hop fewer on hcnet
```

Keep an eye on application error rates and outbound call timeouts for a day or so. If you find a difference, report it through the feedback button.

## Rolling back

Hetzner Console → server → **Networking** → **Network Stack** → **Restore standard network stack**.

Then **reboot, or renew DHCP as in step 3**. This matters more when rolling back: the hcnet-specific routes can stay behind and cause the problem described next.

## Troubleshooting

**Metadata is unreachable after rolling back**

Symptom: `curl http://169.254.169.254/...` hangs, `cloud-init` or the CSI driver complain, and:

```console
$ ip route get 169.254.169.254
169.254.169.254 dev ens10 src 10.0.0.2      # goes via the private interface
```

Cause: a leftover hcnet route sends metadata traffic through the private interface, which the standard stack doesn't serve.

Fix: renew DHCP or reboot. As a temporary fix, delete the stale route:

```bash
sudo ip route del 169.254.169.254 dev ens10
```

**Metadata routes missing after switching to hcnet**

Not harmful: the metadata server still works through the default route. The explicit routes appear at the next DHCP renewal or reboot.

**Outbound connections time out under load, inbound still works**

You may be over 120,000 tracked flows for one IP version. See [Connection tracking in practice](conntrack-in-practice.md#symptoms-of-hitting-the-limit).

**Higher packet counts in monitoring**

Expected on hcnet. See [step 5](#5-watch-for-a-while).

## Rolling out to a fleet

1. Switch one non-critical server, follow steps 1–5, and run it for a few days.
2. Switch one server from each role (web, worker, database, gateway). Servers behind a load balancer are the easiest: take one out of rotation, switch it, verify, and put it back.
3. Do the rest in small batches, one batch per load-balancer pool at a time.
4. Keep a list of which servers you switched. The Console shows the stack per server, but the API doesn't expose it yet, so you can't query it with `hcloud`.

A Hetzner label is a handy way to keep that list in the API:

```bash
hcloud server add-label web-1 netstack=hcnet
hcloud server list -l netstack=hcnet
```
