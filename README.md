# xen-vsock-kernel

Minimal **PV/PVH Xen guest** kernel for Fedora 44, stripped down from the
stock Fedora kernel for use in lightweight VMs. No QEMU, no libvirt, no
virtio — pure PV/PVH with Xen paravirtualized drivers (xen-blkfront,
xen-netfront).

## Why minimal?

The stock Fedora kernel has 4,551 modules (~247M RPMs). A PV guest VM only
needs a fraction of that. This repo builds a minimal kernel with:

- **643 modules** (86% reduction)
- **~26M total RPM size** (90% reduction)
- **12M vmlinuz** (vs 19M stock)
- **24M initramfs** (vs 103M stock)

## Architecture

- **VM type:** PVH (qlvm uses `LIBXL_DOMAIN_TYPE_PVH`)
- **Disk:** xen-blkfront (`CONFIG_XEN_BLKDEV_FRONTEND=y`, built-in)
- **Network:** xen-netfront (`CONFIG_XEN_NETDEV_FRONTEND=y`, built-in)
- **Root filesystem:** XFS (`CONFIG_XFS_FS=y`) with ostree deployment
- **Waypipe:** TCP over xen-netfront (no vsock, no virtio)

## The build

Three-stage `Dockerfile.guest`:

1. **builder** — rpmbuild toolchain + kernel build deps (layer-cached)
2. **kernel** — resolves current Fedora 44 kernel, applies `scripts/minimalize-config.sh` to strip unused subsystems, builds with `ISA_LEVEL=4`
3. **build** — `rpmbuild`, collects RPMs into `/out`

`build-guest.yml` runs the build and publishes as `kernel-xenguest-<VER>`.

## Critical kernel options

These must be built-in (`=y`) for the PVH guest to boot:

- `CONFIG_HYPERVISOR_GUEST=y` — Xen PVH loader requires this
- `CONFIG_XEN=y`, `CONFIG_XEN_PV=y`, `CONFIG_XEN_PVHVM=y`, `CONFIG_XEN_PVH=y`
- `CONFIG_XEN_BLKDEV_FRONTEND=y` — PV disk driver
- `CONFIG_XEN_NETDEV_FRONTEND=y` — PV network driver
- `CONFIG_XEN_CONSOLE_FRONTEND=y` — PV console (hvc0)
- `CONFIG_XFS_FS=y` — root filesystem is XFS
- `CONFIG_BTRFS_FS=y`, `CONFIG_BTRFS_FS_POSIX_ACL=y` — ostree support
- `CONFIG_OVERLAY_FS=y` — ostree root layers
- `CONFIG_MD=y`, `CONFIG_DM=y` + DM sub-options — device-mapper for ostree
- `CONFIG_TIMERFD=y`, `CONFIG_NAMESPACES=y` + sub-namespaces — systemd in initramfs

## Initramfs

The initramfs must include ostree modules for the ostree deployment to boot:

```bash
dracut -f --add ostree /out/initramfs-xenguest "$KVER"
```

## Building locally

```bash
podman build -t xen-guest-kernel:local -f Dockerfile.guest .
# Extract RPMs
CONTAINER=$(podman create xen-guest-kernel:local)
podman cp "$CONTAINER":/out/. /tmp/rpms/
podman rm "$CONTAINER"
# Generate initramfs (in Fedora 44 container)
dnf install dracut ostree
rpm -i /tmp/rpms/kernel-core-*.rpm /tmp/rpms/kernel-modules-*.rpm /tmp/rpms/kernel-modules-core-*.rpm
dracut -f --add ostree /out/initramfs-xenguest "$(ls /lib/modules/)"
```

## Consuming

Install the release assets via `dnf` module in blue-build recipes:

```yaml
- type: dnf
  install:
    packages:
      - https://github.com/jcpowermac/xen-vsock-kernel/releases/download/kernel-xenguest-7.2.9-201.fc44/kernel-7.2.9-201.fc44.x86_64.rpm
      - https://github.com/jcpowermac/xen-vsock-kernel/releases/download/kernel-xenguest-7.2.9-201.fc44/kernel-core-7.2.9-201.fc44.x86_64.rpm
      - https://github.com/jcpowermac/xen-vsock-kernel/releases/download/kernel-xenguest-7.2.9-201.fc44/kernel-modules-7.2.9-201.fc44.x86_64.rpm
      - https://github.com/jcpowermac/xen-vsock-kernel/releases/download/kernel-xenguest-7.2.9-201.fc44/kernel-modules-core-7.2.9-201.fc44.x86_64.rpm
      - https://github.com/jcpowermac/xen-vsock-kernel/releases/download/kernel-xenguest-7.2.9-201.fc44/kernel-modules-extra-7.2.9-201.fc44.x86_64.rpm
```

## Stripped subsystems

Disabled to reduce module count: sound, GPU (DRM/KMS), Bluetooth, WiFi,
Ethernet (non-PV), PHYLIB, MDIO, NETFILTER, thermal, NVMe, NVMEM, IIO,
x86 platform devices, USB, firewire, PCI Express hotplug, SCSI transports
(kept for safety), most TCP congestion algorithms (kept cubic + bbr).

Kept: TPM, hw_random, pvpanic, hangcheck-timer, SELinux, audit, IMA/EVM,
crypto, wireguard, tap, netconsole.
