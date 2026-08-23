#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CONFIG="$SCRIPT_DIR/config.env"
ASSUME_YES=false
while (($#)); do
  case "$1" in
    --yes) ASSUME_YES=true ;;
    --config) shift; CONFIG=${1:?Missing value for --config} ;;
    *) echo "Usage: $0 [--config path] [--yes]" >&2; exit 2 ;;
  esac
  shift
done
[[ -r "$CONFIG" ]] || { echo "Missing $CONFIG; copy config.example.env to config.env" >&2; exit 2; }
# shellcheck disable=SC1090
source "$CONFIG"

[[ "$VM_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] || { echo "Invalid VM_NAME" >&2; exit 1; }
[[ "$VM_NETWORK" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || { echo "Invalid VM_NETWORK" >&2; exit 1; }
[[ "$VM_MAC" =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]] || { echo "Invalid VM_MAC" >&2; exit 1; }
[[ "$VM_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || { echo "Invalid VM_IP" >&2; exit 1; }
[[ "$IMAGE_DIR" == /var/lib/libvirt/images/* && "$IMAGE_DIR" != /var/lib/libvirt/images/ ]] || {
  echo "Refusing unsafe IMAGE_DIR: $IMAGE_DIR" >&2
  exit 1
}

uri=qemu:///system
disk="$IMAGE_DIR/$VM_NAME.qcow2"
seed="$IMAGE_DIR/$VM_NAME-seed.img"
base="$IMAGE_DIR/debian-13-generic-amd64.qcow2"

if [[ "$ASSUME_YES" != true ]]; then
  printf 'This permanently removes VM %s, its overlay, and seed image.\n' "$VM_NAME"
  printf 'The shared checksum-pinned base image is preserved: %s\n' "$base"
  read -r -p "Type the VM name to continue: " confirmation
  [[ "$confirmation" == "$VM_NAME" ]] || { echo "Cancelled."; exit 1; }
fi

if virsh -c "$uri" dominfo "$VM_NAME" >/dev/null 2>&1; then
  state=$(virsh -c "$uri" domstate "$VM_NAME")
  if [[ "$state" != 'shut off' ]]; then
    virsh -c "$uri" destroy "$VM_NAME" >/dev/null
  fi
  virsh -c "$uri" undefine "$VM_NAME" --nvram >/dev/null 2>&1 || \
    virsh -c "$uri" undefine "$VM_NAME" >/dev/null
fi

network_xml=$(virsh -c "$uri" net-dumpxml "$VM_NETWORK")
if grep -qiF "$VM_MAC" <<<"$network_xml" || \
   grep -qF "ip='$VM_IP'" <<<"$network_xml" || \
   grep -qF "ip=\"$VM_IP\"" <<<"$network_xml"; then
  virsh -c "$uri" net-update "$VM_NETWORK" delete ip-dhcp-host \
    "<host mac='$VM_MAC' name='$VM_NAME' ip='$VM_IP'/>" --live --config
fi

sudo rm -f -- "$disk" "$seed"
echo "Removed VM $VM_NAME, DHCP reservation, overlay, and seed image."
echo "Preserved base image: $base"
