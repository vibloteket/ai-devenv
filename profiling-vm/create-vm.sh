#!/usr/bin/env bash
set -euo pipefail

# virsh human-readable fields are localized; parsing must use stable C output.
export LC_ALL=C

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CONFIG=${1:-"$SCRIPT_DIR/config.env"}
[[ -r "$CONFIG" ]] || { echo "Missing $CONFIG; copy config.example.env to config.env" >&2; exit 2; }
# shellcheck disable=SC1090
source "$CONFIG"

required=(curl sha512sum ssh-keygen qemu-img cloud-localds virsh virt-install sed awk perl)
for command in "${required[@]}"; do command -v "$command" >/dev/null || { echo "Missing command: $command" >&2; exit 1; }; done
[[ -r "$SSH_PUBLIC_KEY_FILE" ]] || { echo "Cannot read SSH public key: $SSH_PUBLIC_KEY_FILE" >&2; exit 1; }
public_key=$(<"$SSH_PUBLIC_KEY_FILE")
[[ "$public_key" != *$'\n'* ]] || { echo "SSH public key file must contain exactly one key" >&2; exit 1; }
[[ "$public_key" == ssh-ed25519\ * || "$public_key" == ssh-rsa\ * ]] || { echo "Unsupported SSH public key format" >&2; exit 1; }
ssh-keygen -l -f "$SSH_PUBLIC_KEY_FILE" >/dev/null || { echo "Invalid SSH public key" >&2; exit 1; }
# Cloud-init does not need the free-form comment. Removing it prevents YAML
# metacharacters in a comment from changing the rendered configuration.
read -r key_type key_blob _ <<<"$public_key"
public_key="$key_type $key_blob"
[[ "$VM_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] || { echo "Invalid VM_NAME" >&2; exit 1; }
[[ "$VM_NETWORK" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || { echo "Invalid VM_NETWORK" >&2; exit 1; }
[[ "$VM_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || { echo "Invalid VM_USER" >&2; exit 1; }
[[ "$VM_MAC" =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]] || { echo "Invalid VM_MAC" >&2; exit 1; }
[[ "$VM_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || { echo "Invalid VM_IP" >&2; exit 1; }
IFS=. read -r -a ip_octets <<<"$VM_IP"
for octet in "${ip_octets[@]}"; do
  ((10#$octet <= 255)) || { echo "Invalid VM_IP" >&2; exit 1; }
done
[[ "$VM_VCPUS" =~ ^[1-9][0-9]*$ && "$VM_MEMORY_MB" =~ ^[1-9][0-9]*$ && "$VM_DISK_GB" =~ ^[1-9][0-9]*$ ]] || {
  echo "VM_VCPUS, VM_MEMORY_MB, and VM_DISK_GB must be positive integers" >&2
  exit 1
}
[[ "$IDLE_MINUTES" =~ ^[1-9][0-9]*$ && "$MAX_RUNTIME_HOURS" =~ ^[1-9][0-9]*$ ]] || {
  echo "IDLE_MINUTES and MAX_RUNTIME_HOURS must be positive integers" >&2
  exit 1
}
[[ "$IMAGE_SHA512" =~ ^[[:xdigit:]]{128}$ ]] || { echo "IMAGE_SHA512 must be a SHA-512 digest" >&2; exit 1; }
[[ "$IMAGE_URL" == https://cloud.debian.org/images/cloud/* && "$IMAGE_URL" != */latest/* ]] || {
  echo "IMAGE_URL must be a versioned cloud.debian.org image URL, not latest" >&2
  exit 1
}

uri=qemu:///system
if virsh -c "$uri" dominfo "$VM_NAME" >/dev/null 2>&1; then
  echo "VM $VM_NAME already exists; refusing to overwrite it." >&2
  exit 1
fi
network_info=$(virsh -c "$uri" net-info "$VM_NETWORK")
if ! grep -q '^Active:.*yes' <<<"$network_info"; then
  echo "Network $VM_NETWORK is not active" >&2
  printf '%s\n' "$network_info" >&2
  exit 1
fi

IFS=, read -r -a cpus <<<"$VM_CPUSET"
[[ ${#cpus[@]} -eq $VM_VCPUS ]] || { echo "VM_CPUSET must contain exactly VM_VCPUS CPU IDs" >&2; exit 1; }
declare -A seen_cpus=()
for cpu in "${cpus[@]}"; do
  [[ "$cpu" =~ ^[0-9]+$ && -d "/sys/devices/system/cpu/cpu$cpu" ]] || { echo "Invalid CPU ID in VM_CPUSET: $cpu" >&2; exit 1; }
  if [[ -r "/sys/devices/system/cpu/cpu$cpu/online" ]]; then
    [[ $(<"/sys/devices/system/cpu/cpu$cpu/online") == 1 ]] || { echo "Offline CPU ID in VM_CPUSET: $cpu" >&2; exit 1; }
  fi
  [[ ! ${seen_cpus[$cpu]+set} ]] || { echo "Duplicate CPU ID in VM_CPUSET: $cpu" >&2; exit 1; }
  seen_cpus[$cpu]=1
done

sudo install -d -m 0755 "$IMAGE_DIR"
work=$(mktemp -d)
base="$IMAGE_DIR/debian-13-generic-amd64.qcow2"
disk="$IMAGE_DIR/$VM_NAME.qcow2"
seed="$IMAGE_DIR/$VM_NAME-seed.img"
images_created=0
dhcp_reserved=0

rollback() {
  virsh -c "$uri" destroy "$VM_NAME" >/dev/null 2>&1 || true
  virsh -c "$uri" undefine "$VM_NAME" --nvram >/dev/null 2>&1 || virsh -c "$uri" undefine "$VM_NAME" >/dev/null 2>&1 || true
  if [[ $dhcp_reserved == 1 ]]; then
    virsh -c "$uri" net-update "$VM_NETWORK" delete ip-dhcp-host \
      "<host mac='$VM_MAC' name='$VM_NAME' ip='$VM_IP'/>" --live --config >/dev/null 2>&1 || true
  fi
  if [[ $images_created == 1 ]]; then
    sudo rm -f -- "$disk" "$seed"
  fi
}
cleanup() {
  status=$?
  trap - EXIT INT TERM
  if ((status)); then rollback; fi
  rm -rf "$work"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ ! -f "$base" ]] || ! printf '%s  %s\n' "$IMAGE_SHA512" "$base" | sha512sum --check --status; then
  echo "Downloading and verifying Debian cloud image..."
  curl -fL --retry 3 "$IMAGE_URL" -o "$work/base.qcow2"
  printf '%s  %s\n' "$IMAGE_SHA512" "$work/base.qcow2" | sha512sum --check
  sudo install -m 0644 "$work/base.qcow2" "$base"
fi
[[ ! -e "$disk" && ! -e "$seed" ]] || { echo "Disk or seed already exists in $IMAGE_DIR; remove explicitly before retrying" >&2; exit 1; }
network_xml=$(virsh -c "$uri" net-dumpxml "$VM_NETWORK")
if grep -qiF "$VM_MAC" <<<"$network_xml" || \
   grep -qF "ip='$VM_IP'" <<<"$network_xml" || \
   grep -qF "ip=\"$VM_IP\"" <<<"$network_xml"; then
  echo "A DHCP reservation already uses $VM_MAC or $VM_IP" >&2
  exit 1
fi

indent_file() { sed 's/^/      /' "$1"; }
escape_sed() { printf '%s' "$1" | sed 's/[&|\\]/\\&/g'; }
heartbeat=$(indent_file "$SCRIPT_DIR/guest/profile-heartbeat")
sed "s/__VM_USER__/$(escape_sed "$VM_USER")/g" "$SCRIPT_DIR/guest/idle-poweroff" >"$work/idle"
idle=$(indent_file "$work/idle")
cp "$SCRIPT_DIR/cloud-init/user-data.yaml" "$work/user-data"
sed -i \
  -e "s|__VM_NAME__|$(escape_sed "$VM_NAME")|g" \
  -e "s|__VM_USER__|$(escape_sed "$VM_USER")|g" \
  -e "s|__SSH_PUBLIC_KEY__|$(escape_sed "$public_key")|g" \
  -e "s|__IDLE_MINUTES__|$IDLE_MINUTES|g" \
  -e "s|__MAX_RUNTIME_HOURS__|$MAX_RUNTIME_HOURS|g" \
  "$work/user-data"
HEARTBEAT="$heartbeat" IDLE="$idle" perl -0pi -e 's/__HEARTBEAT_SCRIPT__/$ENV{HEARTBEAT}/; s/__IDLE_SCRIPT__/$ENV{IDLE}/' "$work/user-data"
sed "s/__VM_NAME__/$(escape_sed "$VM_NAME")/g" "$SCRIPT_DIR/cloud-init/meta-data.yaml" >"$work/meta-data"
cloud-localds "$work/seed.img" "$work/user-data" "$work/meta-data"

# The paths were proven absent above, so rollback may safely own them before
# creation and also clean up a partially written image after interruption.
images_created=1
sudo qemu-img create -f qcow2 -F qcow2 -b "$base" "$disk" "${VM_DISK_GB}G"
sudo install -m 0644 "$work/seed.img" "$seed"
sudo chown libvirt-qemu:libvirt-qemu "$disk" "$seed" 2>/dev/null || sudo chown libvirt-qemu:kvm "$disk" "$seed"

# Reserve the address before first boot. Mark it first so an interruption in
# the small window after net-update still attempts a harmless rollback delete.
dhcp_reserved=1
virsh -c "$uri" net-update "$VM_NETWORK" add ip-dhcp-host \
  "<host mac='$VM_MAC' name='$VM_NAME' ip='$VM_IP'/>" --live --config

# Generate and define the domain while it is stopped. Applying CPU affinity to
# a running domain races its first boot and makes early-boot failures harder to
# diagnose. Start only after all persistent configuration is in place.
virt-install --connect "$uri" \
  --name "$VM_NAME" --memory "$VM_MEMORY_MB" --vcpus "$VM_VCPUS" \
  --cpu host-passthrough \
  --disk "path=$disk,format=qcow2,bus=virtio" \
  --disk "path=$seed,device=cdrom" \
  --network "network=$VM_NETWORK,model=virtio,mac=$VM_MAC" \
  --osinfo detect=on,name=debian13 \
  --graphics none --console pty,target.type=serial \
  --import --print-xml >"$work/domain.xml"
virsh -c "$uri" define "$work/domain.xml" >/dev/null

for index in "${!cpus[@]}"; do
  virsh -c "$uri" vcpupin "$VM_NAME" "$index" "${cpus[$index]}" --config
done
virsh -c "$uri" start "$VM_NAME" >/dev/null

echo "VM $VM_NAME started. Cloud-init can take several minutes."
echo "SSH: ssh -i ${SSH_PUBLIC_KEY_FILE%.pub} ${VM_USER}@${VM_IP}"
