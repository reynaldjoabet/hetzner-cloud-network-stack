# A packet's journey, hop by hop

This page follows one download, hop by hop, on three journeys:

1. [VM to VM on another host, over a private network](#journey-1-vm-to-vm-over-a-private-network)
2. [VM to the internet](#journey-2-vm-to-the-internet)
3. [The internet to a VM](#journey-3-the-internet-to-a-vm)

At every step it shows **what the packet looks like and how big it is**. That's where the numbers in the benchmark come from: 1,514 bytes, 1,464 bytes, and "12–38 KB".

For *firewall decisions* on each stack (allow, drop, spoofing, a full table), see [packet walkthroughs](packet-walkthroughs.md).

Hetzner hasn't published every detail of its hosts. The steps inside a VM and the kernel follow standard Linux and KVM behaviour. The steps on the host follow Hetzner's descriptions of each stack and Cloudfleet's measurements.

- [The short version](#the-short-version)
- [Before we start: three ideas](#before-we-start-three-ideas)
- [Journey 1: VM to VM over a private network](#journey-1-vm-to-vm-over-a-private-network)
- [Journey 2: VM to the internet](#journey-2-vm-to-the-internet)
- [Journey 3: the internet to a VM](#journey-3-the-internet-to-a-vm)
- [All three side by side](#all-three-side-by-side)

---

## The short version

Wires carry small frames: at most **1,514 bytes**. Inside a computer, every packet costs CPU time, so Linux works with **big packets** wherever it can. A big packet is up to 64 KB with one set of headers.

- **Sending:** keep the packet big through the software, and cut it into 1,514-byte frames at the last moment.
- **Receiving:** glue the frames back into big packets as early as possible.

The only question that differs between the stacks is **who glues on the way in**.

**Journey 1: VM → VM on another host, over a private network**

```text
  HOST A            ┌──────────────┐
                    │ vm-a app     │  writes 1 MB
                    └──────┬───────┘
                    ┌──────▼───────┐
                    │ vm-a TCP     │  ~16 big packets, ≈64 KB each,
                    └──────┬───────┘  one set of headers each
                           │  virtio: still big
                    ┌──────▼───────┐
                    │ tap          │
                    └──────┬───────┘
                    ┌──────▼───────┐
                    │ OVS or hcnet │  no Cloud Firewall: private networks aren't filtered;
                    └──────┬───────┘  destination 10.0.0.3 lives on host B
                    ┌──────▼───────┐
                    │ VXLAN wrap   │  + outer Eth 14, IP 20, UDP 8, VXLAN 8 = 50 bytes,
                    └──────┬───────┘  addressed host A → host B
                    ┌──────▼───────┐
                    │ NIC: cut     │  ~716 frames of 1,514 bytes:
                    └──────┬───────┘  [outer 50 │ Eth 14 │ IP 20 │ TCP 32 │ data 1,398]
                           ║  datacenter network: switches read only
                           ║  the outer header, "host A → host B"
  HOST B            ┌──────▼───────┐
                    │ NIC: unwrap  │  outer 50 bytes removed → 1,464-byte frames
                    └──────┬───────┘
              ┌────────────┴────────────┐
       ┌──────▼───────┐          ┌──────▼───────┐
       │ STANDARD     │          │ hcnet        │
       │ host glues   │          │ passes each  │
       │ (GRO)        │          │ as is        │
       └──────┬───────┘          └──────┬───────┘
       ~30–80 packets             ~716 packets
         of 12–38 KB             of 1,464 bytes
              └────────────┬────────────┘
                    ┌──────▼───────┐
                    │ vm-b         │  one vCPU handles every packet;
                    └──────────────┘  its own GRO glues; app reads 1 MB
```

The 50-byte wrapper is why the private network's MTU is 1,500 − 50 = **1,450**.

**Journey 2: VM → internet**

```text
  VM                ┌──────────────┐
                    │ web-1 app    │  writes 1 MB
                    └──────┬───────┘
                    ┌──────▼───────┐
                    │ web-1 TCP    │  ~16 big packets, ≈64 KB each
                    └──────┬───────┘
                           │  virtio: still big
  HOST              ┌──────▼───────┐
                    │ tap          │  anti-spoofing: is 203.0.113.7 really web-1's?
                    └──────┬───────┘
                    ┌──────▼───────┐
                    │ Cloud        │  outbound allowed by default;
                    │ Firewall     │  connection RECORDED ← counts toward 80k / 120k
                    └──────┬───────┘
                    ┌──────▼───────┐
                    │ routing      │  public traffic: no VXLAN, routed straight out
                    └──────┬───────┘
                    ┌──────▼───────┐
                    │ NIC: cut     │  ~691 frames of 1,514 bytes:
                    └──────┬───────┘  [Eth 14 │ IP 20 │ TCP 32 │ data 1,448]
                           ║  Hetzner routers → internet
                    ┌──────▼───────┐
                    │ remote       │  the server on the internet glues the frames
                    └──────────────┘  back together (its own GRO); app reads 1 MB
```

Sending looks the same on both stacks.

**Journey 3: internet → VM (where the stacks differ)**

```text
                    ┌──────────────┐
                    │ remote       │  a server on the internet sends 1 MB
                    └──────┬───────┘  as ~691 frames of 1,514 bytes
                           ║  internet → Hetzner routers → web-1's host
  HOST              ┌──────▼───────┐
                    │ NIC          │  ~691 frames arrive
                    └──────┬───────┘
                    ┌──────▼───────┐
                    │ Cloud        │  reply to a RECORDED connection? → allowed
                    │ Firewall     │  brand-new connection? → needs a rule (e.g. TCP 443)
                    └──────┬───────┘
              ┌────────────┴────────────┐
       ┌──────▼───────┐          ┌──────▼───────┐
       │ STANDARD     │          │ hcnet        │
       │ host glues   │          │ passes each  │
       │ (GRO)        │          │ as is        │
       └──────┬───────┘          └──────┬───────┘
       ~25–80 packets             ~691 packets
         of 12–38 KB             of 1,514 bytes
              └────────────┬────────────┘
  VM                ┌──────▼───────┐
                    │ web-1        │  ONE receive vCPU handles every packet
                    └──────────────┘  → why hcnet tops out near 10 Gbit/s
```

In one sentence: **packets leave a VM big on both stacks and travel the wire as 1,514-byte frames. On the way in, the standard stack's host glues them back together for your VM, and hcnet makes your VM do it.**

The sections below go through each step in detail.

---

## Before we start: three ideas

**1. A packet is headers plus data.** Each layer puts its own header in front:

```text
┌──────────┬──────────┬──────────┬──────────────────────────┐
│ Ethernet │ IP       │ TCP      │ data                     │
│ 14 bytes │ 20 bytes │ 32 bytes │ up to 1,448 bytes        │
│ which    │ which    │ which    │ a piece of your file     │
│ machine  │ computer │ program  │                          │
└──────────┴──────────┴──────────┴──────────────────────────┘
```

**2. Real wires carry small packets.** The IP packet on a normal Ethernet link can be at most **1,500 bytes**, its MTU. With the 14-byte Ethernet header, a full frame on the wire is **1,514 bytes**. A 1 MB file therefore crosses the wire as about 700 packets.

**3. Inside a computer, small packets are expensive.** Every packet costs the same fixed amount of CPU work, however small it is. So Linux cheats in both directions:

```text
 sending:    one BIG packet travels through the software ──▶ cut into 1,514-byte frames at the last moment
             (TSO/GSO: segmentation offload)

 receiving:  1,514-byte frames arrive ──▶ glued back into one BIG packet as early as possible
             (GRO: generic receive offload)
```

A "big packet" is up to 64 KB of data with a **single** set of headers, plus a note that says "cut me into 1,448-byte pieces". Software handles it once instead of 45 times.

The difference between the stacks is **whether the host glues packets back together before handing them to your VM**. The standard stack does; hcnet doesn't.

---

## Journey 1: VM to VM over a private network

`vm-a` (private IP `10.0.0.2`, on host A) sends a 1 MB file to `vm-b` (`10.0.0.3`, on host B) over a Hetzner private network. Private interfaces have an MTU of **1,450**, so each piece carries **1,398 bytes** of data.

```text
 HOST A                                                         HOST B
┌───────────────────────────────────┐                        ┌───────────────────────────────────┐
│ vm-a                              │                        │                              vm-b │
│  app ─▶ TCP ─▶ virtio NIC         │                        │         virtio NIC ─▶ TCP ─▶ app  │
│                  │                │                        │              ▲                    │
│ ─────────────────┼─────────────── │                        │ ─────────────┼─────────────────── │
│                  ▼                │                        │              │                    │
│  tap ─▶ OVS or hcnet ─▶ VXLAN ─▶ NIC ══ datacenter network ══▶ NIC ─▶ unwrap ─▶ OVS or hcnet ─▶ tap │
└───────────────────────────────────┘                        └───────────────────────────────────┘
```

### Step 1. The application writes

```text
app in vm-a:  write(socket, file, 1,000,000 bytes)
```

The application only hands bytes to the kernel. There are no packets yet.

### Step 2. vm-a's TCP builds big packets

vm-a's kernel takes up to 64 KB at a time and puts **one** set of headers in front:

```text
┌─────┬────────────┬─────┬──────────────────────────────────────────────────────────┐
│ Eth │ IP         │ TCP │ data: 64,000 bytes                                       │
│ 14  │ 10.0.0.2 → │ 32  │ note: "cut into 1,398-byte pieces"                       │
│     │ 10.0.0.3   │     │                                                          │
└─────┴────────────┴─────┴──────────────────────────────────────────────────────────┘
  ≈ 64 KB    ×  ~16 of these for 1 MB
```

This is segmentation offload. The virtual NIC tells vm-a that "someone else will cut this up", so vm-a's CPU doesn't have to. Hetzner documents that outgoing segmentation offload works on both stacks.

### Step 3. Through the virtual NIC to host A

The big packet is placed in memory shared with the host (virtio). On host A it comes out of the VM's **tap** device, still ≈ 64 KB.

### Step 4. Host A decides where it goes

- Anti-spoofing: is `10.0.0.2` really vm-a's address? Yes.
- Cloud Firewalls **don't** filter private networks, so there's no firewall check and no connection tracking.
- `10.0.0.3` belongs to vm-b, which lives on **host B**. The packet has to cross the datacenter network.

On the standard stack, Open vSwitch flow rules make this decision. On hcnet, eBPF programs do.

### Step 5. Host A wraps it (VXLAN)

The datacenter network only knows how to deliver to **hosts**, not to customer IPs like `10.0.0.3`. Many customers use `10.0.0.0/16` at the same time. So host A puts vm-a's frame inside a new packet addressed from host A to host B:

```text
┌───────────┬──────────────┬─────────┬──────────┬───────────────────────────────────────┐
│ outer Eth │ outer IP     │ UDP     │ VXLAN    │ vm-a's frame, unchanged               │
│ 14        │ host A →     │ 8       │ 8        │ ┌─────┬────┬─────┬─────────────────┐  │
│           │ host B       │ port    │ network  │ │ Eth │ IP │ TCP │ data            │  │
│           │ 20           │ 4789    │ ID       │ └─────┴────┴─────┴─────────────────┘  │
└───────────┴──────────────┴─────────┴──────────┴───────────────────────────────────────┘
```

The VXLAN header carries the private network's ID, so host B knows which customer network this belongs to.

### Step 6. Cut into wire-sized frames

Now the big packet must become real frames. Each piece gets a full copy of **all** the headers, inner and outer, and the outer IP packet must not exceed 1,500 bytes:

```text
One frame on the datacenter wire (1,514 bytes):

┌──────┬──────┬─────┬───────┬──────┬──────┬──────┬──────────────┐
│ Eth  │ IP   │ UDP │ VXLAN │ Eth  │ IP   │ TCP  │ data         │
│ 14   │ 20   │ 8   │ 8     │ 14   │ 20   │ 32   │ 1,398        │
└──────┴──────┴─────┴───────┴──────┴──────┴──────┴──────────────┘
 outer │◀──────────────── outer IP packet: 1,500 ───────────────▶│
       │◀── 50 bytes of wrapper ──▶│◀─ vm-a's IP packet: 1,450 ─▶│
```

That's where the private network's MTU comes from: 1,500 − 50 = **1,450**.

```text
1 big packet (64,000 bytes of data) ──▶ 46 frames of 1,514 bytes
1 MB file                           ──▶ ~716 frames
```

Ideally the physical NIC does this cutting in hardware; otherwise the host's kernel does it in software.

### Step 7. Across the datacenter network

Switches and routers only read the **outer** headers: "UDP from host A to host B". They never look at vm-a's packet inside. Every frame is 1,514 bytes.

### Step 8. Host B unwraps

Host B's NIC receives ~716 frames. Host B removes the 50-byte wrapper from each one, reads the network ID, and finds that vm-b is on that network. What's left is vm-a's original frame:

```text
┌─────┬────┬─────┬──────────────┐
│ Eth │ IP │ TCP │ data         │   14 + 20 + 32 + 1,398 = 1,464 bytes
└─────┴────┴─────┴──────────────┘
```

### Step 9. Host B hands it to vm-b: the stacks differ here

```text
STANDARD STACK                                   hcnet
host B glues consecutive pieces together         host B passes each piece through as is
(GRO):

┌────┬──────────────────────────────────┐        ┌────┬─────┐┌────┬─────┐┌────┬─────┐
│hdrs│ 1,398 × 22 = 30,756 bytes        │        │hdrs│1,398││hdrs│1,398││hdrs│1,398│ ...
└────┴──────────────────────────────────┘        └────┴─────┘└────┴─────┘└────┴─────┘
 1 packet, ~31 KB                                 22 packets, 1,464 bytes each

1 MB ──▶ roughly 30–80 packets into vm-b         1 MB ──▶ ~716 packets into vm-b
```

Gluing works because each TCP piece is numbered by its byte position in the stream. Host B checks that piece 2 starts exactly where piece 1 ended, and that they belong to the same connection. It then keeps piece 1's headers, drops piece 2's, and appends the data.

### Step 10. Inside vm-b

vm-b's virtual NIC has **one receive queue**, so one vCPU handles every arriving packet. With ~716 packets instead of ~40, that vCPU does far more work. It runs its own GRO to glue them together anyway, and then TCP delivers 1,000,000 bytes to the application. The file is identical; only the number of pieces along the way differed.

---

## Journey 2: VM to the internet

`web-1` (public IP `203.0.113.7`) uploads 1 MB to a server on the internet (`198.51.100.20`). The public interface has an MTU of **1,500**, so each piece carries **1,448 bytes**.

```text
 HOST                                                  
┌──────────────────────────────────────────────┐
│ web-1                                        │
│  app ─▶ TCP ─▶ virtio NIC                    │
│ ─────────────────┼────────────────────────── │
│                  ▼                           │
│  tap ─▶ Cloud Firewall ─▶ Linux routing ─▶ NIC ══▶ Hetzner routers ══▶ internet ══▶ 198.51.100.20
│         (OVS + conntrack                      │
│          or hcnet eBPF)                       │
└──────────────────────────────────────────────┘
```

| Step | Where | What the packet looks like |
|---|---|---|
| 1 | App in web-1 | `write()` of 1,000,000 bytes, no packets yet |
| 2 | web-1's TCP | Big packets: one set of headers + up to 64 KB, note "cut into 1,448-byte pieces". About 16 of them. |
| 3 | Virtual NIC → host's tap | Same big packets, ≈ 64 KB each |
| 4 | Host: anti-spoofing | Is `203.0.113.7` really web-1's address? Yes. |
| 5 | Host: **Cloud Firewall** | Outbound is allowed by default. The firewall **records the connection** (`203.0.113.7:51544 ↔ 198.51.100.20:443`) so replies can come back in. This is the entry that counts against 80,000 or 120,000. Standard stack: Open vSwitch hands it to netfilter conntrack. hcnet: the eBPF program stores it in a map. |
| 6 | Host: routing | Public traffic is **not** wrapped in VXLAN. The host routes it straight out of its uplink towards Hetzner's routers. |
| 7 | Host NIC: cut | Each big packet is cut into 1,514-byte frames: `Eth 14 │ IP 20 │ TCP 32 │ data 1,448`. 1 MB ≈ **691 frames**. |
| 8 | Hetzner routers → internet | Each router reads the destination IP and forwards. The frames stay ≤ 1,514 bytes all the way, because most of the internet uses an MTU of 1,500. |
| 9 | Remote server | Its NIC and kernel glue the pieces back together (its own GRO) and hand 1,000,000 bytes to its application. |

**Sending looks the same on both stacks.** The VM sends big packets, and they're cut at the edge. The only difference is where the connection is recorded (step 5). Cloudfleet found that the sending side wasn't the bottleneck on either stack.

---

## Journey 3: the internet to a VM

A server on the internet (`198.51.100.20`) sends 1 MB to `web-1` (`203.0.113.7`), for example a download that web-1 requested.

```text
                                                        HOST
                                                       ┌──────────────────────────────────────────────┐
                                                       │                                       web-1  │
                                                       │                    virtio NIC ─▶ TCP ─▶ app  │
                                                       │                        ▲  (1 vCPU)           │
                                                       │ ───────────────────────┼──────────────────── │
198.51.100.20 ══▶ internet ══▶ Hetzner routers ══▶ NIC ─▶ Linux routing ─▶ Cloud Firewall ─▶ tap     │
                                                       │                 (+ GRO on standard)          │
                                                       └──────────────────────────────────────────────┘
```

| Step | Where | What the packet looks like |
|---|---|---|
| 1 | Remote server | Its TCP builds big packets, its NIC cuts them into 1,514-byte frames |
| 2 | Internet → Hetzner routers | ~691 frames of 1,514 bytes: `Eth 14 │ IP 20 │ TCP 32 │ data 1,448`. Hetzner's routers know which host `203.0.113.7` lives on and send the frames there. |
| 3 | Host NIC | ~691 frames arrive |
| 4 | Host: **Cloud Firewall** | Is this a reply to a tracked connection? Yes: web-1 opened it in a step like Journey 2's step 5, so it's allowed back in. A brand-new inbound connection would instead need a rule, such as "allow TCP 443". |
| 5 | Host → tap: **the stacks differ** | See below |
| 6 | web-1's virtual NIC | One receive queue: one vCPU handles every packet |
| 7 | web-1's kernel | Its own GRO glues pieces together, TCP checks the order, the app reads 1,000,000 bytes |

Step 5 in detail:

```text
STANDARD STACK                                   hcnet
the host glues consecutive frames before         the eBPF firewall checks each frame and
handing them to the VM:                          passes it through unchanged:

wire:  ▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮                    wire:  ▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮
host:  ████████  ████████  ██████                host:  ▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮
       (glued: 12–38 KB each, measured)                 (1,514 bytes each, measured)
VM:    3 packets to handle                       VM:    22 packets to handle

1 MB ──▶ about 25–80 packets into web-1          1 MB ──▶ ~691 packets into web-1
```

**This is the journey where hcnet is slower.** Same data, 8–20× more packets, all handled by web-1's single receive vCPU. Cloudfleet measured that vCPU at 93–97% busy on hcnet, with receive throughput at about 10 Gbit/s instead of about 17. See [benchmarks](benchmarks.md#why-plain-tcp-throughput-drops).

Small traffic, such as an API request, a DNS answer or an SSH keystroke, is a single packet anyway. Nothing gets glued, and it looks identical on both stacks.

---

## All three side by side

For 1 MB of data:

| | Journey 1: private, VM → VM | Journey 2: VM → internet | Journey 3: internet → VM |
|---|---|---|---|
| Data per wire frame | 1,398 bytes | 1,448 bytes | 1,448 bytes |
| Frame on the wire | 1,514 bytes, of which 50 are the VXLAN wrapper | 1,514 bytes | 1,514 bytes |
| Frames on the wire | ~716 | ~691 | ~691 |
| Leaves the sending VM as | ~16 big packets | ~16 big packets | — |
| Cloud Firewall and connection tracking | No (private networks aren't filtered) | Yes, connection recorded | Yes, checked against the table or rules |
| Arrives in the receiving VM as, **standard** | ~30–80 glued packets (≈ 12–38 KB) | — | ~25–80 glued packets (≈ 12–38 KB) |
| Arrives in the receiving VM as, **hcnet** | ~716 packets of 1,464 bytes | — | ~691 packets of 1,514 bytes |

The rule to remember: **packets leave a VM big on both stacks, and they're cut into 1,514-byte frames for the wire. On the way in, the standard stack's host glues them back together before your VM sees them; hcnet hands your VM every frame separately.**
