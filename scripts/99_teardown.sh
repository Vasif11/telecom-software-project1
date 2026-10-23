#!/usr/bin/env bash
# Remove everything deploy.sh created. Usage: sudo ./scripts/99_teardown.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
source config/topology.env
[[ $EUID -eq 0 ]] || { echo "Run with sudo"; exit 1; }

docker compose -f docker/compose.yml down

for net in "$UE_NET" "$ACC_NET" "$CORE_NET"; do
  iptables -D DOCKER-USER -s "$net" -d "$DN_NET" -j ACCEPT 2>/dev/null
  iptables -D DOCKER-USER -s "$DN_NET" -d "$net" -j ACCEPT 2>/dev/null
done

for ns in "$UE_NS" "$ACC_NS" "$CORE_NS"; do ip netns del "$ns" 2>/dev/null; done
# Deleting host-dn also removes the host routes that used it.
ip link del "$HOST_DN_IF" 2>/dev/null
echo "Scenario A removed."
