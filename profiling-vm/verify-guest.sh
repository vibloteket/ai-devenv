#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CONFIG=${1:-"$SCRIPT_DIR/config.env"}
# shellcheck disable=SC1090
source "$CONFIG"
key=${SSH_PRIVATE_KEY_FILE:-${SSH_PUBLIC_KEY_FILE%.pub}}
[[ -r "$key" ]] || { echo "Cannot read SSH private key: $key" >&2; exit 1; }
ssh=(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -i "$key" "$VM_USER@$VM_IP")
"${ssh[@]}" bash -s <<'REMOTE'
set -eu
test -e /var/lib/cloud/instance/provisioning-complete
printf 'Host: '; hostname
printf 'CPU: '; grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ //'
printf 'Tools: '; command -v cc cmake ninja perf valgrind >/dev/null && echo OK
printf 'Perf policy: '; cat /proc/sys/kernel/perf_event_paranoid
perf_output=$(mktemp)
trap 'rm -f "$perf_output"' EXIT
perf stat -x, -o "$perf_output" \
  -e cycles:u,instructions:u,branches:u,branch-misses:u,cache-misses:u \
  -- sha256sum /usr/bin/perf >/dev/null
cat "$perf_output"
awk -F, '
  $3 ~ /^(cycles|instructions|branches):u$/ {
    value=$1; gsub(/[[:space:]]/, "", value)
    if(value !~ /^[0-9]+$/ || value == 0) exit 1
    seen++
  }
  END { exit(seen == 3 ? 0 : 1) }
' "$perf_output" || {
  echo 'Hardware performance counters returned no usable counts' >&2
  exit 1
}
printf 'Idle timer: '; systemctl is-active profiling-vm-idle-poweroff.timer
REMOTE
