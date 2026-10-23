# Project 1 – Network Deployment, Measurement and Observability (Scenario A)

**Course:** Telecommunications Software – Riga Technical University
**Author:** Vasif Yusifli

A software-based telecommunications network built on one Linux VM with a hybrid
**Linux namespaces + Docker** design:

```
UE / Client  →  Access Network  →  Core Network / Gateway  →  Data Network  →  Application Server
 (netns ue)      (netns access)       (netns core)            (host + Docker bridge)   (Nginx, iperf3)
```

Workflow followed: **Deploy → Verify → Observe → Measure → Diagnose → Explain**.

---

## 1. Topology

```
 netns ue            netns access                    netns core                      Linux host                 Docker bridge br-dn (10.0.4.0/24)
┌──────────────┐    ┌──────────────────────┐       ┌──────────────────────┐       ┌─────────────────────┐    ┌───────────────────────────────┐
│ UE / Client  │    │ Access Router        │       │ Core / Gateway       │       │ Integration boundary│    │ scenario-a-nginx  10.0.4.10:80 │
│ eth0         │veth│ acc-ue    acc-core   │ veth  │ core-acc   core-dn   │ veth  │ host-dn      br-dn  │    │ scenario-a-iperf3 10.0.4.20:5201│
│ 10.0.1.10/24 ├────┤ 10.0.1.1  10.0.2.1   ├───────┤ 10.0.2.2   10.0.3.1  ├───────┤ 10.0.3.2   10.0.4.1 ├────┤ (TCP + UDP)                   │
└──────────────┘    └──────────────────────┘       └──────────────────────┘       └─────────────────────┘    └───────────────────────────────┘
     10.0.1.0/24 (UE link)        10.0.2.0/24 (access–core)       10.0.3.0/24 (core–host)                 10.0.4.0/24 (data network)
```

### Addressing plan

| Node | Namespace | Interface | IP address | Subnet | Peer |
|---|---|---|---|---|---|
| UE / Client | `ue` | `eth0` | 10.0.1.10 | 10.0.1.0/24 | Access `acc-ue` |
| Access Router | `access` | `acc-ue` | 10.0.1.1 | 10.0.1.0/24 | UE `eth0` |
| Access Router | `access` | `acc-core` | 10.0.2.1 | 10.0.2.0/24 | Core `core-acc` |
| Core / Gateway | `core` | `core-acc` | 10.0.2.2 | 10.0.2.0/24 | Access `acc-core` |
| Core / Gateway | `core` | `core-dn` | 10.0.3.1 | 10.0.3.0/24 | Host `host-dn` |
| Host (integration) | root | `host-dn` | 10.0.3.2 | 10.0.3.0/24 | Core `core-dn` |
| Host (DN gateway) | root | `br-dn` | 10.0.4.1 | 10.0.4.0/24 | Docker bridge |
| Application server | container | `eth0` | 10.0.4.10 | 10.0.4.0/24 | Nginx, TCP 80 |
| Measurement server | container | `eth0` | 10.0.4.20 | 10.0.4.0/24 | iperf3, TCP/UDP 5201 |

All values live in [`config/topology.env`](config/topology.env); every script reads them from there.

### Routing

| Node | Destination | Next hop | Why |
|---|---|---|---|
| UE | default | 10.0.1.1 | All UE traffic enters the access network |
| Access | 10.0.1.0/24 | connected | UE is directly attached |
| Access | default | 10.0.2.2 | Everything else is upstream, via the core |
| Core | 10.0.1.0/24 | 10.0.2.1 | Return path to the UE is through access |
| Core | default | 10.0.3.2 | The data network is behind the host gateway |
| Host | 10.0.1.0/24, 10.0.2.0/24 | 10.0.3.1 | Return path into the namespace network |
| Host | 10.0.4.0/24 | connected (`br-dn`) | Docker data network |

IP forwarding is enabled in `access`, `core` and on the host. Without it these nodes would drop packets not addressed to themselves.

---

## 2. How application traffic crosses the path

An HTTP request from the UE (`curl http://10.0.4.10/`) travels as follows:

1. **UE** (`10.0.1.10`, ephemeral port) opens a TCP connection to `10.0.4.10:80`. The destination is not on its own subnet, so it is sent to its default gateway `10.0.1.1` on `eth0`.
2. **Access router** receives it on `acc-ue`, looks up `10.0.4.10`, and forwards it via `acc-core` to `10.0.2.2`. TTL is decreased by 1.
3. **Core / gateway** receives it on `core-acc` and forwards it via `core-dn` to the host `10.0.3.2`.
4. **Host** receives it on `host-dn`. `10.0.4.0/24` is directly connected on `br-dn`, so it forwards it into the Docker bridge. The firewall rules in the `DOCKER-USER` chain allow this.
5. **Nginx** (`10.0.4.10:80`) answers. The reply follows the reverse route `br-dn → host-dn → core → access → ue`.

The Docker network uses `gateway_mode_ipv4=routed`, so **no NAT** happens anywhere on the path. Nginx sees the real UE address, which the verification checks in the Nginx access log. This keeps the path honest: every hop is a plain IP router, as in an operator network.

---

## 3. Requirements

* Ubuntu 22.04 or 24.04 VM (2 vCPU, 4 GB RAM, 30 GB disk is enough)
* Docker Engine **27 or newer** (needed for the routed bridge mode) with the Compose plugin
* `iproute2`, `tcpdump`, `tshark`, `iperf3`, `curl`, `traceroute`, Python 3 with NumPy, pandas, Matplotlib

`scripts/00_install_prereqs.sh` installs all of these.

## 4. Quick start

```bash
git clone <this repo> && cd scenario-a
sudo ./scripts/00_install_prereqs.sh     # once, on a fresh VM (then log out and back in)
sudo ./scripts/deploy.sh                 # build namespaces + start containers
sudo ./scripts/03_verify.sh              # collect Step 1 evidence (PASS/FAIL report)
sudo ./scripts/99_teardown.sh            # remove everything
```

Handy manual commands:

```bash
sudo ip netns exec ue curl -v http://10.0.4.10/        # application test from the UE
sudo ip netns exec ue traceroute -n 10.0.4.10           # path: 10.0.1.1 → 10.0.2.2 → 10.0.3.2 → 10.0.4.10
sudo ip netns exec ue iperf3 -c 10.0.4.20               # TCP throughput to the measurement server
sudo ip netns exec core tcpdump -ni core-acc            # watch traffic inside the core
```

## 5. Step 1 – verification

`scripts/03_verify.sh` checks each layer separately, because a successful ping alone does not prove the path works:

| Layer | What is checked | Evidence |
|---|---|---|
| Topology | namespaces exist, interfaces up with the planned IPs | `ip netns`, `ip -br addr` |
| Routing | forwarding on, next hop correct at **every** node | `ip route`, `ip route get 10.0.4.10` per node |
| Services | containers running, sockets listening on 80 and 5201 | `docker compose ps`, `ss -ltnup` in each container |
| Network | each hop answers ICMP from the UE | `ping` to 6 addresses |
| Path | traffic really takes UE → access → core → host → app | `traceroute` hop list |
| Transport + application | TCP connect, HTTP 200, correct page, timings | `curl -v`, `curl -w` |
| End-to-end identity | server sees the UE address (no NAT) | Nginx access log |
| Measurement endpoint | iperf3 TCP and UDP tests complete | `iperf3` |

The report is saved to `results/step1/verify_<timestamp>.txt`.

## 6. Repository layout

```
config/topology.env          names and addresses (single source of truth)
docker/compose.yml           Data Network bridge + Nginx + iperf3
docker/nginx/                Nginx config (timing log format) and web content
scripts/00_install_prereqs.sh
scripts/01_deploy_namespaces.sh   UE / access / core namespaces, veth links, routes
scripts/02_deploy_services.sh     containers + host firewall rules
scripts/deploy.sh                 runs 01 + 02
scripts/03_verify.sh              Step 1 evidence report
scripts/99_teardown.sh
results/                     measurement output and captures, one folder per step
```

## 7. Design notes

* **Nginx port 80 instead of 8080.** The reference figure mentions 8080 for the app service. Here the UE reaches the container IP directly (routed, no port publishing), so Nginx keeps its standard port 80.
* **UE interface named `eth0`.** This matches the reference figure. It is created under a temporary name and renamed inside the namespace, so it never clashes with a host interface.
* **Test files** `file_100K.bin`, `file_1M.bin` and `file_10M.bin` are generated at deploy time and used later for HTTP transfer-time measurements. They are not committed.
