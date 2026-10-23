#!/usr/bin/env bash
# Start the containerized Data Network (Nginx + iperf3 on bridge br-dn) and
# open the host firewall between the namespace network and the Data Network.
set -euo pipefail
cd "$(dirname "$0")/.."
source config/topology.env
[[ $EUID -eq 0 ]] || { echo "Run with sudo"; exit 1; }

echo "[1/3] Test content for HTTP transfer-time measurements"
for size in 100K 1M 10M; do
  f="docker/nginx/html/file_${size}.bin"
  [[ -f $f ]] || head -c "$size" /dev/urandom > "$f"
done

echo "[2/3] Start containers"
docker compose -f docker/compose.yml up -d
docker compose -f docker/compose.yml ps

echo "[3/3] Host firewall (DOCKER-USER chain)"
# Docker sets the FORWARD policy to DROP. DOCKER-USER is the chain Docker reserves for
# admin rules; it is evaluated first. Allow namespace subnets <-> Data Network both ways.
if iptables -n -L DOCKER-USER >/dev/null 2>&1; then
  for net in "$UE_NET" "$ACC_NET" "$CORE_NET"; do
    for rule in "-s $net -d $DN_NET" "-s $DN_NET -d $net"; do
      # shellcheck disable=SC2086
      iptables -C DOCKER-USER $rule -j ACCEPT 2>/dev/null || iptables -I DOCKER-USER $rule -j ACCEPT
    done
  done
  iptables -n -v -L DOCKER-USER
else
  echo "WARNING: DOCKER-USER chain not found (non-iptables Docker firewall?)."
fi

echo "Services ready: Nginx $NGINX_IP:$NGINX_PORT, iperf3 $IPERF_IP:$IPERF_PORT"
