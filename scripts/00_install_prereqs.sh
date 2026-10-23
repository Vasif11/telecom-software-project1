#!/usr/bin/env bash
# Install everything Scenario A needs on a fresh Ubuntu 22.04/24.04 VM.
# Usage: sudo ./scripts/00_install_prereqs.sh
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo"; exit 1; }

export DEBIAN_FRONTEND=noninteractive
# Let non-root users in the 'wireshark' group capture packets (answers the tshark install prompt).
echo "wireshark-common wireshark-common/install-setuid boolean true" | debconf-set-selections

apt-get update
apt-get install -y \
  iproute2 iputils-ping iputils-tracepath traceroute ethtool net-tools conntrack \
  tcpdump tshark wireshark iperf3 netcat-openbsd curl jq git \
  python3 python3-numpy python3-pandas python3-matplotlib

# Docker Engine + Compose plugin (official convenience script).
if ! command -v docker >/dev/null; then
  curl -fsSL https://get.docker.com | sh
fi

# The routed gateway mode used in docker/compose.yml needs Docker >= 27.
ver=$(docker version --format '{{.Server.Version}}' | cut -d. -f1)
(( ver >= 27 )) || echo "WARNING: Docker $ver found, version 27+ is required."

# Allow the normal user to run docker / capture without sudo (re-login needed).
user=${SUDO_USER:-}
if [[ -n $user ]]; then
  usermod -aG docker,wireshark "$user"
  echo "Added $user to docker and wireshark groups - log out and back in."
fi

docker pull nginx:stable-alpine
docker pull networkstatic/iperf3
echo "Prerequisites installed."
