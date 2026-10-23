#!/usr/bin/env bash
# Build the Linux-namespace part of Scenario A:
#   UE (ns ue) --veth-- Access Router (ns access) --veth-- Core/Gateway (ns core) --veth-- Linux host
# Safe to re-run: it removes any previous copy first.
set -euo pipefail
cd "$(dirname "$0")/.."
source config/topology.env
[[ $EUID -eq 0 ]] || { echo "Run with sudo"; exit 1; }

echo "[1/5] Clean previous state"
for ns in "$UE_NS" "$ACC_NS" "$CORE_NS"; do ip netns del "$ns" 2>/dev/null || true; done
ip link del "$HOST_DN_IF" 2>/dev/null || true

echo "[2/5] Create namespaces"
for ns in "$UE_NS" "$ACC_NS" "$CORE_NS"; do
  ip netns add "$ns"
  ip -n "$ns" link set lo up
done

echo "[3/5] Create veth links"
# Link 1: UE <-> Access. Created with a temporary name, then renamed to eth0 inside the UE
# namespace (a host might already have an eth0, the namespace never does).
ip link add ue-tmp0 type veth peer name "$ACC_UE_IF"
ip link set ue-tmp0 netns "$UE_NS"
ip -n "$UE_NS" link set ue-tmp0 name "$UE_IF"
ip link set "$ACC_UE_IF" netns "$ACC_NS"
# Link 2: Access <-> Core
ip link add "$ACC_CORE_IF" type veth peer name "$CORE_ACC_IF"
ip link set "$ACC_CORE_IF" netns "$ACC_NS"
ip link set "$CORE_ACC_IF" netns "$CORE_NS"
# Link 3: Core <-> Host (host end stays in the root namespace = integration boundary)
ip link add "$CORE_DN_IF" type veth peer name "$HOST_DN_IF"
ip link set "$CORE_DN_IF" netns "$CORE_NS"

echo "[4/5] Assign addresses and bring links up"
ip -n "$UE_NS"   addr add "$UE_IP/24"       dev "$UE_IF"
ip -n "$ACC_NS"  addr add "$ACC_UE_IP/24"   dev "$ACC_UE_IF"
ip -n "$ACC_NS"  addr add "$ACC_CORE_IP/24" dev "$ACC_CORE_IF"
ip -n "$CORE_NS" addr add "$CORE_ACC_IP/24" dev "$CORE_ACC_IF"
ip -n "$CORE_NS" addr add "$CORE_DN_IP/24"  dev "$CORE_DN_IF"
ip addr add "$HOST_DN_IP/24" dev "$HOST_DN_IF"
ip -n "$UE_NS"   link set "$UE_IF" up
ip -n "$ACC_NS"  link set "$ACC_UE_IF" up
ip -n "$ACC_NS"  link set "$ACC_CORE_IF" up
ip -n "$CORE_NS" link set "$CORE_ACC_IF" up
ip -n "$CORE_NS" link set "$CORE_DN_IF" up
ip link set "$HOST_DN_IF" up

echo "[5/5] Routing and IP forwarding"
# UE: everything goes to its access router (like a phone's default bearer).
ip -n "$UE_NS" route add default via "$ACC_UE_IP"
# Access: knows the UE subnet directly, sends everything else upstream to the core.
ip -n "$ACC_NS" route add default via "$CORE_ACC_IP"
# Core/Gateway: UE subnet is behind access, everything else (data network) is behind the host.
ip -n "$CORE_NS" route add "$UE_NET" via "$ACC_CORE_IP"
ip -n "$CORE_NS" route add default via "$HOST_DN_IP"
# Host: return routes toward the namespace network (the DN bridge 10.0.4.0/24 is directly connected).
ip route replace "$UE_NET"  via "$CORE_DN_IP" dev "$HOST_DN_IF"
ip route replace "$ACC_NET" via "$CORE_DN_IP" dev "$HOST_DN_IF"
# Routers must forward packets that are not addressed to themselves.
ip netns exec "$ACC_NS"  sysctl -qw net.ipv4.ip_forward=1
ip netns exec "$CORE_NS" sysctl -qw net.ipv4.ip_forward=1
sysctl -qw net.ipv4.ip_forward=1

echo "Namespace topology ready."
