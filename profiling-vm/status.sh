#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CONFIG=${1:-"$SCRIPT_DIR/config.env"}
# shellcheck disable=SC1090
source "$CONFIG"
uri=qemu:///system
virsh -c "$uri" dominfo "$VM_NAME"
printf '\nDHCP leases:\n'
virsh -c "$uri" net-dhcp-leases "$VM_NETWORK" || true
printf '\nPinned vCPUs:\n'
virsh -c "$uri" vcpupin "$VM_NAME" || true
