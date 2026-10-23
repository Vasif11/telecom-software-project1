#!/usr/bin/env bash
# Step 1 evidence: prove each layer of the UE -> Access -> Core -> DN -> App path works.
# Every command and its output goes to results/step1/verify_<time>.txt, plus a PASS/FAIL summary.
# Usage: sudo ./scripts/03_verify.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
source config/topology.env
[[ $EUID -eq 0 ]] || { echo "Run with sudo"; exit 1; }

mkdir -p results/step1
OUT="results/step1/verify_$(date +%Y%m%d_%H%M%S).txt"
exec > >(tee "$OUT") 2>&1

PASS=0; FAIL=0
section() { printf '\n==================== %s ====================\n' "$1"; }
run()     { echo "\$ $*"; "$@" 2>&1; echo; }
check() {  # check "<description>" <command...>  -> PASS if command exits 0
  local d=$1; shift
  if "$@" >/dev/null 2>&1; then echo "[PASS] $d"; ((PASS++)); else echo "[FAIL] $d"; ((FAIL++)); fi
}
in_ns() { ip netns exec "$@"; }

echo "Scenario A verification - $(date -Is) - host $(hostname)"

section "1. Namespaces"
run ip netns list
for ns in "$UE_NS" "$ACC_NS" "$CORE_NS"; do check "namespace $ns exists" test -e "/run/netns/$ns"; done

section "2. Interfaces and addresses"
for ns in "$UE_NS" "$ACC_NS" "$CORE_NS"; do echo "--- ns $ns ---"; run ip -n "$ns" -br addr; done
echo "--- host (integration boundary + Docker DN bridge) ---"
run ip -br addr show "$HOST_DN_IF"
run ip -br addr show "$DN_BRIDGE"
check "UE      $UE_IF has $UE_IP"           bash -c "ip -n $UE_NS addr show $UE_IF | grep -q 'inet $UE_IP/'"
check "Access  $ACC_UE_IF has $ACC_UE_IP"   bash -c "ip -n $ACC_NS addr show $ACC_UE_IF | grep -q 'inet $ACC_UE_IP/'"
check "Access  $ACC_CORE_IF has $ACC_CORE_IP" bash -c "ip -n $ACC_NS addr show $ACC_CORE_IF | grep -q 'inet $ACC_CORE_IP/'"
check "Core    $CORE_ACC_IF has $CORE_ACC_IP" bash -c "ip -n $CORE_NS addr show $CORE_ACC_IF | grep -q 'inet $CORE_ACC_IP/'"
check "Core    $CORE_DN_IF has $CORE_DN_IP"  bash -c "ip -n $CORE_NS addr show $CORE_DN_IF | grep -q 'inet $CORE_DN_IP/'"
check "Host    $HOST_DN_IF has $HOST_DN_IP"  bash -c "ip addr show $HOST_DN_IF | grep -q 'inet $HOST_DN_IP/'"
check "Host    $DN_BRIDGE has $DN_GW"        bash -c "ip addr show $DN_BRIDGE | grep -q 'inet $DN_GW/'"

section "3. Routing tables and forwarding"
for ns in "$UE_NS" "$ACC_NS" "$CORE_NS"; do echo "--- ns $ns ---"; run ip -n "$ns" route; done
echo "--- host (relevant routes) ---"
run bash -c "ip route | grep -E '10\.0\.[1-4]\.'"
for ns in "$ACC_NS" "$CORE_NS"; do
  check "ip_forward=1 in $ns" bash -c "[[ \$(ip netns exec $ns sysctl -n net.ipv4.ip_forward) == 1 ]]"
done
check "ip_forward=1 on host" bash -c "[[ \$(sysctl -n net.ipv4.ip_forward) == 1 ]]"

echo "--- Forwarding decision at every hop (ip route get) ---"
run ip -n "$UE_NS"   route get "$NGINX_IP"
run ip -n "$ACC_NS"  route get "$NGINX_IP"
run ip -n "$CORE_NS" route get "$NGINX_IP"
run ip route get "$NGINX_IP"
run ip route get "$UE_IP"
check "UE     -> app next hop $ACC_UE_IP"   bash -c "ip -n $UE_NS route get $NGINX_IP | grep -q 'via $ACC_UE_IP'"
check "Access -> app next hop $CORE_ACC_IP" bash -c "ip -n $ACC_NS route get $NGINX_IP | grep -q 'via $CORE_ACC_IP'"
check "Core   -> app next hop $HOST_DN_IP"  bash -c "ip -n $CORE_NS route get $NGINX_IP | grep -q 'via $HOST_DN_IP'"
check "Host   -> app out $DN_BRIDGE"        bash -c "ip route get $NGINX_IP | grep -q 'dev $DN_BRIDGE'"
check "Host   -> UE next hop $CORE_DN_IP"   bash -c "ip route get $UE_IP | grep -q 'via $CORE_DN_IP'"

section "4. Docker Data Network and services"
run docker compose -f docker/compose.yml ps
run docker network inspect scenario-a-dn --format \
  'name={{.Name}} driver={{.Driver}} subnet={{(index .IPAM.Config 0).Subnet}} gw={{(index .IPAM.Config 0).Gateway}} options={{.Options}}'
run docker inspect -f '{{.Name}} ip={{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}} state={{.State.Status}}' "$NGINX_CTR" "$IPERF_CTR"
check "Nginx container running"  bash -c "[[ \$(docker inspect -f '{{.State.Running}}' $NGINX_CTR) == true ]]"
check "iperf3 container running" bash -c "[[ \$(docker inspect -f '{{.State.Running}}' $IPERF_CTR) == true ]]"

echo "--- Listening sockets inside each container (host ss in the container's netns) ---"
for c in "$NGINX_CTR" "$IPERF_CTR"; do
  pid=$(docker inspect -f '{{.State.Pid}}' "$c")
  echo "--- $c (pid $pid) ---"; run nsenter -t "$pid" -n ss -ltnup
done
check "Nginx listening on TCP $NGINX_PORT"  bash -c "nsenter -t \$(docker inspect -f '{{.State.Pid}}' $NGINX_CTR) -n ss -ltn | grep -q ':$NGINX_PORT '"
check "iperf3 listening on TCP $IPERF_PORT" bash -c "nsenter -t \$(docker inspect -f '{{.State.Pid}}' $IPERF_CTR) -n ss -ltn | grep -q ':$IPERF_PORT '"

echo "--- Host firewall rules for the DN ---"
run iptables -n -v -L DOCKER-USER

section "5. Hop-by-hop reachability from the UE (ICMP)"
for hop in "$ACC_UE_IP" "$CORE_ACC_IP" "$HOST_DN_IP" "$DN_GW" "$NGINX_IP" "$IPERF_IP"; do
  run in_ns "$UE_NS" ping -c 3 -i 0.2 -W 1 "$hop"
  check "UE ping $hop" in_ns "$UE_NS" ping -c 3 -i 0.2 -W 1 "$hop"
done

section "6. Path taken UE -> application server (traceroute)"
TR=$(in_ns "$UE_NS" traceroute -n -q 1 -w 1 "$NGINX_IP" 2>&1); echo "$TR"; echo
HOPS=$(echo "$TR" | awk 'NR>1{print $2}' | xargs)   # just the hop addresses, space separated
echo "Hops: $HOPS"
check "path goes $ACC_UE_IP -> $CORE_ACC_IP -> $HOST_DN_IP -> $NGINX_IP" \
  test "$HOPS" = "$ACC_UE_IP $CORE_ACC_IP $HOST_DN_IP $NGINX_IP"

section "7. Application test: HTTP UE -> Nginx"
URL="http://$NGINX_IP:$NGINX_PORT/"
run in_ns "$UE_NS" curl -sS -v "$URL"
FMT='http_code=%{http_code} local=%{local_ip}:%{local_port} remote=%{remote_ip}:%{remote_port} size=%{size_download}B tcp_connect=%{time_connect}s ttfb=%{time_starttransfer}s total=%{time_total}s\n'
run in_ns "$UE_NS" curl -sS -o /dev/null -w "$FMT" "$URL"
check "HTTP 200 from $URL" bash -c "[[ \$(ip netns exec $UE_NS curl -s -o /dev/null -w '%{http_code}' $URL) == 200 ]]"
check "Response body is the Scenario A page" bash -c "ip netns exec $UE_NS curl -s $URL | grep -q 'Scenario A'"
echo "--- Nginx access log (client address as seen by the server) ---"
run docker logs --tail 5 "$NGINX_CTR"
check "Nginx saw the real UE address $UE_IP (no NAT on the path)" \
  bash -c "docker logs --tail 20 $NGINX_CTR 2>&1 | grep -q '^$UE_IP:'"

section "8. Measurement endpoint: iperf3 UE -> iperf3 server"
run in_ns "$UE_NS" iperf3 -c "$IPERF_IP" -p "$IPERF_PORT" -t 3
check "iperf3 TCP test completes" in_ns "$UE_NS" iperf3 -c "$IPERF_IP" -p "$IPERF_PORT" -t 2
run in_ns "$UE_NS" iperf3 -c "$IPERF_IP" -p "$IPERF_PORT" -u -b 10M -t 3
check "iperf3 UDP test completes" in_ns "$UE_NS" iperf3 -c "$IPERF_IP" -p "$IPERF_PORT" -u -b 10M -t 2

section "SUMMARY"
echo "PASS=$PASS FAIL=$FAIL"
echo "Evidence saved to $OUT"
(( FAIL == 0 ))
