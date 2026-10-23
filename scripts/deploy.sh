#!/usr/bin/env bash
# One command to build the whole Scenario A network. Usage: sudo ./scripts/deploy.sh
set -euo pipefail
cd "$(dirname "$0")"
./01_deploy_namespaces.sh
./02_deploy_services.sh
echo
echo "Deployment done. Run: sudo ./scripts/03_verify.sh"
