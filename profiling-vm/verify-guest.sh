#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CONFIG=${1:-"$SCRIPT_DIR/config.env"}
# shellcheck disable=SC1090
source "$CONFIG"
key=${SSH_PUBLIC_KEY_FILE%.pub}
ssh=(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -i "$key" "$VM_USER@$VM_IP")
"${ssh[@]}" 'set -eu
  test -e /var/lib/cloud/instance/provisioning-complete
  printf "Host: "; hostname
  printf "CPU: "; grep -m1 "model name" /proc/cpuinfo | cut -d: -f2- | sed "s/^ //"
  printf "Tools: "; command -v cc cmake ninja perf valgrind >/dev/null && echo OK
  printf "Perf policy: "; cat /proc/sys/kernel/perf_event_paranoid
  perf stat -x, -e cycles:u,instructions:u,branches:u,branch-misses:u,cache-misses:u -- true 2>&1
  systemctl is-active profiling-vm-idle-poweroff.timer
'
