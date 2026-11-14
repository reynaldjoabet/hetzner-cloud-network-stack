# Kubernetes LoadBalancer Services on Hetzner

A Kubernetes Service with `type: LoadBalancer` gets a real Hetzner Load Balancer in front of it. This page explains what creates that Load Balancer, how a packet gets from a client to your pod, and how this setup uses your nodes' Cloud Firewall connection budget.

- [What `type: LoadBalancer` does](#what-type-loadbalancer-does)
- [Who creates the Load Balancer](#who-creates-the-load-balancer)
- [Built in two stages: NodePort first](#built-in-two-stages-nodeport-first)
- [The three ports](#the-three-ports)
- [The packet path](#the-packet-path)
- [The same path on each stack](#the-same-path-on-each-stack)
- [How the Load Balancer picks a node](#how-the-load-balancer-picks-a-node)
- [externalTrafficPolicy: Cluster vs Local](#externaltrafficpolicy-cluster-vs-local)
- [Connection tracking and Cloud Firewalls](#connection-tracking-and-cloud-firewalls)
- [Recommended setup](#recommended-setup)

---

## What `type: LoadBalancer` does

This is the example from the Kubernetes documentation:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-service
spec:
  selector:
    app.kubernetes.io/name: MyApp
  ports:
    - protocol: TCP
      port: 80
      targetPort: 9376
  clusterIP: 10.0.171.239
  type: LoadBalancer
status:
  loadBalancer:
    ingress:
    - ip: 192.0.2.127
```

On a cloud that supports it, `type: LoadBalancer` asks the cloud to create an external load balancer for the Service. Creation is **asynchronous**. You apply the Service, and a little later its `.status.loadBalancer.ingress` field fills in with the load balancer's public IP, `192.0.2.127` above. Until then, `kubectl get svc` shows the external IP as `<pending>`.

A `LoadBalancer` Service is built on the two simpler types:

| Type | What you get | Reachable from |
|---|---|---|
| `ClusterIP` | A virtual IP (`10.0.171.239`) | Inside the cluster only |
| `NodePort` | The above, plus a port opened on **every node** | Anyone who can reach a node's IP |
| `LoadBalancer` | The above, plus an external load balancer that forwards to that node port | The internet, through the load balancer's IP |

---

## Who creates the Load Balancer

Kubernetes itself doesn't know about Hetzner. A cluster add-on, the **Hetzner cloud controller manager** (`hcloud-cloud-controller-manager`), watches for `LoadBalancer` Services and talks to the Hetzner API:

```text
 kubectl apply ──▶ API server ──▶ hcloud-cloud-controller-manager ──▶ Hetzner Cloud API
                                         │
                                         ├─ 1. create a Load Balancer (or reuse one by name)
                                         ├─ 2. add the cluster nodes as targets
                                         ├─ 3. add one LB service per port: 80 → node port 31234
                                         └─ 4. write the LB's IPs into .status.loadBalancer
```

It keeps watching. When nodes join or leave, or the Service changes, it updates the Load Balancer to match. When you delete the Service, it deletes the Load Balancer.

You configure the Load Balancer with **annotations** on the Service, for example:

| Annotation | Effect |
|---|---|
| `load-balancer.hetzner.cloud/location` | Where to create it, e.g. `fsn1`, `nbg1`, `hel1` |
| `load-balancer.hetzner.cloud/type` | Size of the Load Balancer, e.g. `lb11` |
| `load-balancer.hetzner.cloud/use-private-ip` | `"true"`: reach the nodes over their private network instead of public IPs |
| `load-balancer.hetzner.cloud/uses-proxyprotocol` | `"true"`: pass the client's IP to the backend with the PROXY protocol |

See the controller's documentation for the full list.

---

## Built in two stages: NodePort first

A `LoadBalancer` Service is assembled in two stages, by two different components:

```text
 you apply: type: LoadBalancer
        │
        ▼
┌──────────────────────────────┐
│ STAGE 1: Kubernetes itself   │   the same as if you had asked for type: NodePort
│                              │
│  • picks a node port,        │   e.g. 31234, from 30000–32767
│    the same on every node    │
│  • kube-proxy (or the CNI)   │   on every node: traffic to :31234
│    sets up forwarding        │   ──▶ one of the Service's pods :9376
└──────────────┬───────────────┘
               │  the Service now works through any node's IP :31234
               ▼
┌──────────────────────────────┐
│ STAGE 2: the cloud           │   hcloud-cloud-controller-manager
│ controller manager           │
│                              │
│  • creates the Hetzner LB    │
│  • targets: every node       │
│  • LB :80 ──▶ node :31234    │
│  • writes the LB IP into     │   .status.loadBalancer.ingress
│    the Service's status      │
└──────────────────────────────┘
```

So the Hetzner Load Balancer never talks to pods directly. It only knows about **servers** (your nodes) and **one port** on them. Getting from that node port to a pod, possibly on another node, is Kubernetes' job (stage 1). Choosing which node to send each connection to is Hetzner's job (stage 2).

Two consequences:

- **The Service works before the Load Balancer exists.** While the external IP still shows `<pending>`, you can already reach the Service at any node's IP on the node port, if a firewall allows it.
- **Keep `allocateLoadBalancerNodePorts` at its default (`true`).** Kubernetes lets you skip stage 1's node port for load balancers that can reach pods directly. Hetzner's Load Balancer forwards to node ports, so it needs one.

---

## The three ports

| Field | In the example | Meaning |
|---|---|---|
| `port` | 80 | What clients connect to, on the Load Balancer IP and on the `clusterIP` |
| `nodePort` | not set, so Kubernetes picks one from 30000–32767, e.g. 31234 | What the Load Balancer connects to, on every node |
| `targetPort` | 9376 | What the container actually listens on |

---

## The packet path

```text
                                  ┌──────────────── node A ────────────────┐
client ──▶ Hetzner Load Balancer ──▶ Cloud Firewall ──▶ :31234 ──▶ kube-proxy ──▶ pod :9376
           192.0.2.127:80         │  (public IPs only)              │       │
           (runs on hcnet)        └─────────────────────────────────┼───────┘
                                                                    │ pod is on another node
                                                                    ▼
                                                    node B ──▶ pod :9376
```

1. The client connects to `192.0.2.127:80`.
2. **The Hetzner Load Balancer is a proxy.** It completes the client's TCP connection itself, picks a healthy target, and opens a **new** connection to that node's port 31234. The node sees the Load Balancer as the source, not the client, unless you enable the PROXY protocol.
3. On the node, `kube-proxy` (or an eBPF CNI such as Cilium) rewrites the destination to one of the Service's pods on port 9376.
4. If that pod runs on another node, the packet is forwarded there: one more hop.

All Hetzner Load Balancers already run on hcnet; Hetzner moved them between 9 July and 21 August 2026. Your nodes may still be on the standard stack.

---

## The same path on each stack

The Load Balancer always runs on hcnet. What changes is the stack of the **host your node runs on**. The two diagrams follow one new client connection with **public-IP targets**, so the node's Cloud Firewall applies. Words in CAPITALS in the notes mark where the two stacks differ.

### Node on the standard stack

```text
                      ┌────────────────┐
                      │ client         │  opens a connection to 192.0.2.127:80
                      └───────┬────────┘
                              ║  internet
                      ┌───────▼────────┐
                      │ Hetzner LB     │  already on hcnet, whatever your nodes run;
                      │                │  health check + round robin picks a node;
                      └───────┬────────┘  opens a NEW connection: LB ──▶ node :31234
                              ║  public IPs (no use-private-ip)
  HOST (standard)     ┌───────▼────────┐
                      │ uplink NIC     │  ~1,514-byte frames arrive
                      └───────┬────────┘
                      ┌───────▼────────┐
                      │ GRO on host    │  consecutive frames glued as they come off
                      └───────┬────────┘  the NIC: 12–38 KB packets from here on
                      ┌───────▼────────┐
                      │ Linux routing  │  host routes 203.0.113.x to the OVS bridge
                      └───────┬────────┘
                      ┌───────▼────────┐
                      │ Open vSwitch   │  anti-spoofing, then ct() hands the packet to
                      │ flow tables    │  the kernel's netfilter conntrack
                      └───────┬────────┘
                      ┌───────▼────────┐
                      │ netfilter      │  NEW flow: entry counted by ctcount against
                      │ conntrack      │  80,000, IPv4 + IPv6 SHARED;
                      └───────┬────────┘  full ──▶ DROPPED, even if a rule allows :31234
                      ┌───────▼────────┐
                      │ tap ──▶ VM     │  few, big packets into the node's virtio NIC
                      └───────┬────────┘
  NODE VM             ┌───────▼────────┐
                      │ kube-proxy     │  DNAT :31234 ──▶ pod :9376, recorded in the
                      │ (in the node)  │  NODE's own conntrack (nf_conntrack_max,
                      └───────┬────────┘  separate from Hetzner's table)
                      ┌───────▼────────┐
                      │ pod :9376      │  on this node, or with externalTrafficPolicy: Cluster
                      │                │  possibly another node: back out through the host,
                      └────────────────┘  where that hop is a 2nd tracked flow on the same 80,000
```

### Node on hcnet

```text
                      ┌────────────────┐
                      │ client         │  opens a connection to 192.0.2.127:80
                      └───────┬────────┘
                              ║  internet
                      ┌───────▼────────┐
                      │ Hetzner LB     │  already on hcnet, whatever your nodes run;
                      │                │  health check + round robin picks a node;
                      └───────┬────────┘  opens a NEW connection: LB ──▶ node :31234
                              ║  public IPs (no use-private-ip)
  HOST (hcnet)        ┌───────▼────────┐
                      │ uplink NIC     │  ~1,514-byte frames arrive
                      └───────┬────────┘
                      ┌───────▼────────┐
                      │ eBPF program   │  the node's Cloud Firewall, compiled; anti-spoofing
                      │ for this VM    │  and rules run here, before any switch
                      └───────┬────────┘
                      ┌───────▼────────┐
                      │ conntrack map  │  NEW flow: entry in this VM's map, 120,000
                      │ per IP version │  for IPv4 and 120,000 for IPv6, SEPARATE;
                      └───────┬────────┘  full ──▶ rule for :31234? passed UNTRACKED
                      ┌───────▼────────┐
                      │ no merging     │  frames reach the VM as they came off the wire:
                      └───────┬────────┘  1,514 bytes each
                      ┌───────▼────────┐
                      │ tap ──▶ VM     │  8–20× more packets into the node's virtio NIC;
                      └───────┬────────┘  ONE receive vCPU handles them all
  NODE VM             ┌───────▼────────┐
                      │ kube-proxy     │  DNAT :31234 ──▶ pod :9376, recorded in the
                      │ (in the node)  │  NODE's own conntrack (nf_conntrack_max,
                      └───────┬────────┘  separate from Hetzner's table)
                      ┌───────▼────────┐
                      │ pod :9376      │  on this node, or with externalTrafficPolicy: Cluster
                      │                │  possibly another node: back out through the host,
                      └────────────────┘  where that hop is a 2nd tracked flow in the same map
```

### Side by side

| Step | Node on the standard stack | Node on hcnet |
|---|---|---|
| Who runs the Cloud Firewall | Open vSwitch flows plus the kernel's netfilter conntrack | A per-VM eBPF program plus its maps |
| Connection budget | 80,000, IPv4 and IPv6 **shared** | 120,000 IPv4 **and** 120,000 IPv6 |
| Table full, new LB connection to `:31234` | **Dropped**, even though a rule allows it | **Passed untracked**, because a rule allows it |
| Table full, the node's own outbound calls (image pulls, APIs, DNS) | Dropped | Fail: replies have no entry and no rule |
| Recovery after a spike | ~1 minute (44–64 s measured) | 0–3 s |
| Packets into the node | Few, glued (12–38 KB) | Many, unglued (1,514 bytes), all on one vCPU |
| Good fit for | Nodes that receive bulk data (ingest, backups, replicas) | Nodes with many connections, such as ingress and API traffic |

**Inside the node, both stacks are identical.** kube-proxy (or your CNI) records its own NAT in the node's kernel conntrack. That table is separate from Hetzner's and is usually larger (`kube-proxy` sets at least 131,072).

### With private-IP targets

With `load-balancer.hetzner.cloud/use-private-ip: "true"`, the Load Balancer reaches the node over the private network. The middle of both diagrams changes:

```text
  Hetzner LB ══ VXLAN over the datacenter network ══▶ node's host
                                                        │  unwrap (50 bytes off)
                                                        │  NO Cloud Firewall, NO entry used
                                                        ▼
                                standard: glued (12–38 KB)   hcnet: 1,464-byte frames
                                                        │
                                                        ▼
                                              node VM (private NIC) ──▶ kube-proxy ──▶ pod
```

The connection budget drops out of the picture on both stacks. The packet-count difference, glued or not, stays.

---

## How the Load Balancer picks a node

Kubernetes says "the cloud provider decides how it is load balanced". On Hetzner, that means the Load Balancer's own settings, which the controller sets from annotations:

```text
                           ┌──────────────────────────┐
  client connections ────▶ │ Hetzner Load Balancer    │
                           │                          │
                           │ 1. health check:         │──▶ node A :31234  ✓ healthy
                           │    which nodes answer?   │──▶ node B :31234  ✓ healthy
                           │                          │──▶ node C :31234  ✗ skipped
                           │ 2. algorithm:            │
                           │    round robin or        │
                           │    least connections     │
                           └────────────┬─────────────┘
                                        │ one node per connection
                                        ▼
                                 node A or node B
```

- **Health checks** decide which nodes are eligible. The controller points them at the node port. With `externalTrafficPolicy: Local`, a node without a pod for this Service fails the check, so it receives no traffic.
- **The algorithm** picks among healthy nodes: **round robin** (the default) or **least connections** (`load-balancer.hetzner.cloud/algorithm-type`).
- **The choice is per connection.** All packets of one TCP connection go to the same node. A long-lived connection, such as a WebSocket or HTTP/2, stays on its node for its whole life.
- **The Load Balancer balances across nodes, not pods.** If node A runs 3 pods and node B runs 1, round robin still sends half the connections to each node. With `externalTrafficPolicy: Cluster`, kube-proxy then spreads them across all 4 pods, at the cost of the extra hop. With `Local`, node B's single pod gets half of all traffic.

---

## externalTrafficPolicy: Cluster vs Local

| | `Cluster` (default) | `Local` |
|---|---|---|
| Which nodes the Load Balancer uses | All nodes | Only nodes running a pod of this Service. The others fail the health check. |
| Extra hop to another node | Possible | Never |
| Client IP inside the cluster | Lost (the first node rewrites the source) | Preserved, though the Hetzner LB is still the source unless you use the PROXY protocol |
| Spread of load | Even across pods | Even across *nodes*, so uneven if nodes run different numbers of pods |

---

## Connection tracking and Cloud Firewalls

This is where the Service type meets the connection limits from [conntrack in practice](conntrack-in-practice.md):

- **Every client connection becomes a Load Balancer → node connection.** Because the Load Balancer is a proxy, the node tracks one connection per client connection. The Load Balancer's address is the source, and the source ports vary.
- **Public or private decides whether it counts.** Cloud Firewalls only filter public interfaces. If the Load Balancer reaches the nodes over **public IPs**, each of those connections uses an entry in the node's table (80,000 shared on the standard stack, or 120,000 per IP version on hcnet). With `use-private-ip: "true"`, the traffic goes over the private network and **doesn't use the budget at all**.
- **`Cluster` can double the count.** When the first node forwards to a pod on another node over public IPs, that node tracks two flows for one client connection: one in from the Load Balancer and one out to the other node. See the [Kubernetes node example](conntrack-in-practice.md#worked-examples).
- **Public targets need the node port open.** For the Load Balancer to reach `:31234` over public IPs, the Cloud Firewall must allow inbound TCP 30000–32767, ideally only from the Load Balancer's IPs. Over a private network you don't need that rule.
- **The Load Balancer has a limit too.** Each Load Balancer type has its own maximum number of connections, separate from your nodes' tables. Check Hetzner's current figures for the type you use.

---

## Recommended setup

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-service
  annotations:
    load-balancer.hetzner.cloud/location: fsn1
    load-balancer.hetzner.cloud/use-private-ip: "true"      # LB → nodes over the private network
spec:
  type: LoadBalancer
  externalTrafficPolicy: Local                               # no extra hop between nodes
  selector:
    app.kubernetes.io/name: MyApp
  ports:
    - protocol: TCP
      port: 80
      targetPort: 9376
```

- **Private network targets** keep Load Balancer traffic out of the Cloud Firewall table, and the node ports stay closed to the internet.
- **`externalTrafficPolicy: Local`** removes the extra hop. Use it when pods are spread across nodes reasonably evenly.
- **PROXY protocol** (`uses-proxyprotocol: "true"`) passes the real client IP, if your ingress controller is configured to read it. Turn it on in both places at once, or the connections will fail.
- **Watch the nodes, not just the Load Balancer.** Outbound traffic, DNS and node-to-node traffic over public IPs still count against each node's table. See [Estimating your usage](conntrack-in-practice.md#estimating-your-usage-from-inside-the-vm).
