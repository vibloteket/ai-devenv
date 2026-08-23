# Disposable profiling VM

Creates a KVM/libvirt Debian 13 VM for repeatable native profiling without
adding `perf` privileges to the main AI container or Docker host workloads.
The VM uses libvirt's private NAT network, a checksum-pinned Debian cloud
image, SSH-key-only login, non-migratable host CPU passthrough, and vCPU
pinning. Disabling CPU migration filtering is intentional: it preserves the
host-specific PMU needed by `perf`.

## Security model

- No host directory is mounted in the guest.
- Root login and SSH passwords are disabled.
- The guest contains no credentials except its dedicated SSH public key.
- `perf_event_paranoid=1` applies inside the guest only.
- The VM has no autostart; an idle timer powers it off after 30 minutes.
- After provisioning, a six-hour maximum runtime is an unconditional failsafe.
- The scripts never modify the host's physical interface or default route.

The guest can still access the network through NAT. Treat it as an isolated
build machine, do not store unrelated secrets there, and keep libvirt/QEMU
patched.

## Host requirements

Debian 13 packages:

```sh
sudo apt install --no-install-recommends \
  qemu-system-x86 qemu-utils libvirt-daemon-system libvirt-clients \
  virtinst cloud-image-utils libguestfs-tools ovmf dnsmasq-base genisoimage
```

The calling user must belong to `libvirt` and `kvm`. The system libvirt
network `default` must be active. Verify with:

```sh
virt-host-validate qemu
virsh -c qemu:///system net-list --all
```

## Create the VM

Create a dedicated key and local configuration:

```sh
ssh-keygen -t ed25519 -f ~/.ssh/munk2d-profiler -C munk2d-profiler
cp profiling-vm/config.example.env profiling-vm/config.env
$EDITOR profiling-vm/config.env
profiling-vm/create-vm.sh
```

`config.env`, private keys, images, and seed disks are ignored by Git. The
script refuses to replace an existing VM, disk, or DHCP reservation. If an
older `config.env` still points at an image under `/latest/`, copy the current
versioned `IMAGE_URL` and matching `IMAGE_SHA512` from `config.example.env`.

The default address is `192.168.122.10`. It is directly reachable from the
libvirt host. Access from another container/network may require a narrowly
scoped host port-forward; do not expose guest SSH publicly.

Cloud-init package installation can take several minutes. Check progress:

```sh
profiling-vm/status.sh
ssh -i ~/.ssh/munk2d-profiler benchmark@192.168.122.10 \
  'cloud-init status --wait --long'
profiling-vm/verify-guest.sh
```

The verification runs user-space hardware counters for cycles, instructions,
branches, branch misses, and cache misses. The generated libvirt domain
explicitly enables its virtual PMU. Failure usually means the host KVM PMU is
disabled or host policy blocks it.

## Keeping a long job alive

Interactive SSH sessions keep the VM alive. Unattended profiling scripts
should run this at least once every 30 minutes:

```sh
profile-heartbeat
```

A typical job can update it in a background loop. The maximum six-hour runtime
still applies and is intended to stop wedged jobs.

## Recreate a failed disposable VM

If provisioning fails, remove the domain, its DHCP reservation, overlay, and
seed consistently before trying again:

```sh
profiling-vm/destroy-vm.sh
profiling-vm/create-vm.sh
```

The destroy script asks you to type the VM name and preserves the downloaded,
checksum-verified Debian base image. Use `--yes` only in trusted automation.
Never remove the base image just to retry cloud-init.

## Power control

The guest user can shut down only through the exact sudoers command installed
by cloud-init:

```sh
sudo systemctl poweroff
```

From the host:

```sh
virsh -c qemu:///system start munk2d-profiler
virsh -c qemu:///system shutdown munk2d-profiler
```

A separately authenticated, command-restricted host start/status endpoint for
PiClaw should be installed only after the VM and networking are verified.
