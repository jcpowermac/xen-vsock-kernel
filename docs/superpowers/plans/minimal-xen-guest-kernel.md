# Minimal Xen Guest Kernel Build

## Context

The current `xen-vsock-kernel` repo builds full Fedora 44 kernels (supporting the entire x86-64 hardware matrix) with vsock+Xen patched in. The original goal failed because `CONFIG_XEN_VSOCKETS` doesn't exist — vsock on Xen requires `CONFIG_VIRTIO_VSOCKETS` (bridged by `CONFIG_XEN_VIRTIO=y`, already built-in).

**New goal**: Build a minimal kernel that runs *only* on Xen guest VMs. Strip the ~4,500 modules for real hardware (sound, USB, GPU, storage controllers, wireless, etc.) that guests never use. Keep the existing build untouched.

**Discovery**: vsock IS possible on Xen via the virtio transport:
- `CONFIG_VSOCKETS=y` (core)
- `CONFIG_VIRTIO_VSOCKETS=y` (transport)
- `CONFIG_XEN_VIRTIO=y` (already built-in — Xen bridges virtio devices)

## Scope

- **Only guest kernels** — dom0 keeps the full Fedora kernel
- **Btrfs is required** — `CONFIG_BTRFS_FS=y` (root filesystem)
- **Two new artifacts**: minimal kernel RPMs + new blue-build recipe
- **Existing build preserved** — new Dockerfile + workflow alongside current ones

## Kernel configuration strategy

Start from Fedora's `kernel-x86_64-fedora.config` (already fetched in the build), apply a curated minimalization patch. This is safer than `xen_defconfig` (which misses Fedora-specific requirements like SELinux, btrfs, etc.) and more maintainable than hand-writing a full config.

### Must keep (built-in)

| Category | Options | Reason |
|----------|---------|--------|
| Xen core | All existing `CONFIG_XEN_*=y` | Paravirt foundation |
| Xen frontends | `CONFIG_XEN_NETDEV_FRONTEND=y`, `CONFIG_XEN_BLKDEV_FRONTEND=y` | Boot-critical (promote from `=m`) |
| Virtio | `CONFIG_VIRTIO=y`, `CONFIG_VIRTIO_BLK=y`, `CONFIG_VIRTIO_PCI=y` | `CONFIG_XEN_VIRTIO=y` bridges these |
| vsock | `CONFIG_VSOCKETS=y`, `CONFIG_VSOCKETS_LOOPBACK=y`, `CONFIG_VIRTIO_VSOCKETS=y` | waypipe channels |
| Filesystems | `CONFIG_BTRFS_FS=y`, `CONFIG_EXT4_FS=y`, `CONFIG_TMPFS=y`, `CONFIG_PROC_FS=y`, `CONFIG_DEVPTS_FS=y`, `CONFIG_AUTOFS_FS=y`, `CONFIG_CONFIGFS_FS=y` | Root fs + system essentials |
| Networking | `CONFIG_INET=y`, `CONFIG_IPV6=y`, `CONFIG_UNIX=y`, `CONFIG_NET=y`, `CONFIG_PACKET=y`, `CONFIG_VIRTIO_NET=m`, `CONFIG_XEN_NETDEV_FRONTEND=y` | Network stack |
| Security | `CONFIG_SECURITY_SELINUX=y`, `CONFIG_AUDIT=y`, `CONFIG_IMA=y`, `CONFIG_EVM=y`, `CONFIG_INTEGRITY=y`, `CONFIG_LSM="lockdown,selinux"` | Fedora security stack |
| Debug | `CONFIG_DEBUG_FS=y`, `CONFIG_KALLSYMS=y` | Module dependency + panic reports |
| Power | `CONFIG_PM=y`, `CONFIG_CPU_FREQ=y`, `CONFIG_CPU_IDLE=y` | vCPU frequency/idle |
| EFI | `CONFIG_EFI=y`, `CONFIG_EFI_STUB=y` | HVM boot |
| ISA | Keep `ISA_LEVEL=4` patch | x86-64-v4 targeting |

### Strip to disabled (guest kernel)

**Modules (=m → off) — ~4,200+ options:**
- All sound: `CONFIG_SND*` (491 modules)
- All USB: `CONFIG_USB*` (285 modules)
- All GPU/display: `CONFIG_DRM*`, `CONFIG_VGA*`, `CONFIG_FB_*` (204 modules)
- All storage controllers: `CONFIG_SCSI*`, `CONFIG_IDE*`, `CONFIG_SATA*`, `CONFIG_AHCI*`, etc. (112 modules)
- All wireless: `CONFIG_BT*`, `CONFIG_WLAN*`, `CONFIG_MAC80211*`, `CONFIG_ATH*`, `CONFIG_IWLW*` (103 modules)
- All I2C/SPI: `CONFIG_I2C*`, `CONFIG_SPI*` (87 modules)
- Real network drivers: all `CONFIG_*` ethernet/WiFi drivers except `r8169` (keep for flexibility)
- All input: `CONFIG_INPUT*` (52 modules)
- Filesystems: strip all except the "must keep" list (~35 filesystems)
- Non-Xen hypervisors: `CONFIG_KVM*`, `CONFIG_HYPERV*`, `CONFIG_ACRN*`, `CONFIG_VMWARE*` (28 modules)
- vsock transports: strip `CONFIG_HYPERV_VSOCKETS`, `CONFIG_VMWARE_VMCI_VSOCKETS`, keep `CONFIG_VIRTIO_VSOCKETS`
- Xen backends: `CONFIG_XEN_*_BACKEND*` (guests don't run backends)
- Xen SCSI: `CONFIG_XEN_SCSI_*` (use blkfront)
- Xen pciback: `CONFIG_XEN_PCIDEV_BACKEND` (guests don't do passthrough)
- Xen pcifront: `CONFIG_XEN_PCIDEV_FRONTEND` (not needed for basic VMs)
- Xen wdt: `CONFIG_XEN_WDT` (not needed)
- Xen fbdev: `CONFIG_XEN_FBDEV_FRONTEND` (demote to m or strip)
- Xen acpi processor: `CONFIG_XEN_ACPI_PROCESSOR` (m is fine)

**Built-ins (=y → off) — ~100 options:**
- Debug/trace: `CONFIG_FTRACE`, `CONFIG_DYNAMIC_FTRACE`, `CONFIG_FUNCTION_TRACER`, `CONFIG_DYNAMIC_DEBUG`, `CONFIG_LATENCYTOP`, `CONFIG_MMIOTRACE`, `CONFIG_RCU_TRACE`, `CONFIG_BLK_DEV_IO_TRACE`, `CONFIG_PM_DEBUG`, `CONFIG_PM_TRACE`, `CONFIG_DM_DEBUG`, `CONFIG_ACPI_DEBUG`, `CONFIG_SLUB_DEBUG`, all subsystem `*_DEBUG` for stripped subsystems
- Non-Xen virt: `CONFIG_KVM_GUEST`, `CONFIG_ACRN_GUEST`, `CONFIG_HYPERV`
- Filesystem extras: `CONFIG_USB_CONFIGFS_F_FS`, `CONFIG_SND_PROC_FS`, `CONFIG_XEN_DEBUG_FS`, `CONFIG_BLK_DEBUG_FS`, `CONFIG_F2FS_STAT_FS`, `CONFIG_SCSI_PROC_FS`
- Security extras: `CONFIG_SECURITY_TOMOYO`, `CONFIG_SECURITY_IPE`, `CONFIG_SECURITY_INFINIBAND`
- Power extras: `CONFIG_SUSPEND`, `CONFIG_HIBERNATE`, APM, real hardware thermal
- Real HW interfaces: `CONFIG_MFD_*`, `CONFIG_REGULATOR_*` (mostly)

### Build output

Same 5 RPMs as current build, but much smaller:
- `kernel-core` — vmlinux (~8-10MB vs ~30MB) + minimal built-ins
- `kernel-modules` — ~50-100 modules vs ~4,500
- `kernel-modules-core`, `kernel-modules-extra` — minimal

## Implementation

### Task 1: Create minimal kernel config patch file

**File**: `config/guest-minimal.config`

A file containing the delta changes applied to Fedora's base config. Format: one `CONFIG_OPTION=value` or `# CONFIG_OPTION is not set` per line. Applied after Fedora's base config is loaded.

**Content**: Generated from the Fedora config + strip list. Start by creating a helper script or the patch file directly.

**Why separate file**: More maintainable than embedding 100+ sed commands in the Dockerfile. Easier to review what's being changed.

### Task 2: Create `Dockerfile.guest`

**File**: `Dockerfile.guest`

Based on the existing `Dockerfile`, with these changes:

1. **Same 3-stage structure** (builder, kernel, build) for cache compatibility
2. **Kernel stage changes**:
   - Instead of 2 sed patches (vsock), apply the full minimalization
   - Use `scripts/config` or a series of `sed`/`echo` commands to apply `config/guest-minimal.config`
   - Keep release +1 bump
   - Keep `ISA_LEVEL=4` patch
   - Change release suffix to distinguish: e.g., `-201.fc44.xenguest` instead of `-201.fc44`
3. **Build stage changes**:
   - Same `rpmbuild` command
   - Same RPM collection

**Key difference from current Dockerfile**: Instead of:
```dockerfile
sed -i 's/^CONFIG_VSOCKETS=m/CONFIG_VSOCKETS=y/' "$CFG"
(grep -q '^CONFIG_XEN_VSOCKETS' "$CFG" || echo 'CONFIG_XEN_VSOCKETS=y' >> "$CFG")
```

Use:
```dockerfile
# Apply minimal guest config on top of Fedora base
cat /config/guest-minimal.config >> "$CFG"
# (or use a merge script that handles overrides properly)
```

**Config merge strategy**: The appended config lines override earlier ones (kernel config processing uses last-value-wins). So appending `CONFIG_SND=y` → `# CONFIG_SND is not set` works. But we need to be careful with options that have sub-options.

**Alternative**: Use the kernel's `scripts/kconfig/merge_config.sh` tool (if available in the build environment) for proper merging.

### Task 3: Create `build-guest.yml` workflow

**File**: `.github/workflows/build-guest.yml`

Same as `build.yml` but:
- References `Dockerfile.guest` via `-f Dockerfile.guest`
- Tags: `kernel-xenguest-${{ kver }}`
- Release name: `kernel-xenguest-${{ kver }}`
- Body mentions "Minimal Xen guest kernel"

### Task 4: Create new blue-build recipe

**File**: `../os/recipes/xenguest.yml`

Based on `bolt.yml`, with the kernel RPM URLs pointing to the minimal kernel releases:

```yaml
---
name: os-xenguest
description: Headless Xen guest VM with minimal kernel for waypipe-projected UI VMs.
base-image: quay.io/fedora/fedora-bootc
image-version: 44
modules:
  - type: dnf
    install:
      packages:
        - https://github.com/jcpowermac/xen-vsock-kernel/releases/download/kernel-xenguest-<VER>/kernel-<VER>.x86_64.rpm
        - https://github.com/jcpowermac/xen-vsock-kernel/releases/download/kernel-xenguest-<VER>/kernel-core-<VER>.x86_64.rpm
        - https://github.com/jcpowermac/xen-vsock-kernel/releases/download/kernel-xenguest-<VER>/kernel-modules-<VER>.x86_64.rpm
        - https://github.com/jcpowermac/xen-vsock-kernel/releases/download/kernel-xenguest-<VER>/kernel-modules-core-<VER>.x86_64.rpm
  - type: rpm-ostree
    install:
      - waypipe
      - firefox
      - systemd-networkd
      - nmap-ncat
      - xwayland-satellite
```

**Note**: The `dnf` module must run BEFORE `rpm-ostree` install so the kernel is available. The exact module ordering in blue-build may need verification.

### Task 5: Test and iterate

1. Build the minimal kernel locally (`docker build -f Dockerfile.guest`)
2. Verify the resulting `.config` has the expected options
3. Check RPM sizes (expect ~90% reduction in modules)
4. Test boot in a Xen guest VM
5. Verify vsock channels work (virtio-vsock)
6. Verify btrfs root filesystem works
7. Iterate on the config as issues surface

---

## Implementation ledger

**Branch:** main (working in place per user request)

### Rulings
- Config approach: transformation script (`scripts/minimalize-config.sh`) applied at build time, not a static config file — picks up Fedora kernel updates automatically
- Package naming: keep standard `kernel-*` names (don't rename to `kernel-xenguest-*`); distinguish via release tag `kernel-xenguest-<VER>`
- Guest-only: strip all backends, PCI passthrough, all real HW drivers
- vsock via virtio-vsock (not non-existent xen-vsock)

### Deferred minors
- Recipe has PLACEHOLDER kernel version — update after first build
- Config script may need iteration based on actual boot test failures
- No automated verification of the minimal config against a bootable reference yet

---

## Risks and mitigations

| Risk | Mitigation |
|------|-----------|
| Missing kernel module at boot (initramfs) | Keep the existing full kernel as fallback in the same image; dracut may need extra config to include xen/virtio modules |
| SELinux policy expects modules that are stripped | Test with SELinux enforcing; may need to strip more security options or add policies |
| `CONFIG_XEN_VIRTIO=y` requires virtio PCI backend in Xen | Verify Xen toolstack exposes virtio-vsock device; may need `xl` config changes |
| Config merge conflicts | Use `merge_config.sh` if available; otherwise test carefully |
| Btrfs needs specific kernel features | `CONFIG_BTRFS_FS=y` is already built-in; verify no sub-options are stripped |
| Waypipe vsock doesn't work with virtio-vsock | Test early; fallback is TCP if vsock proves problematic |

## Success criteria

- Minimal kernel builds successfully via `Dockerfile.guest`
- Kernel RPMs are ~90% smaller than current build
- Xen guest VM boots with minimal kernel
- Btrfs root filesystem mounts and works
- vsock channel works for waypipe (via virtio-vsock)
- Network works (xen-netfront or virtio-net)
- Storage works (xen-blkfront or virtio-blk)
- New recipe `xenguest.yml` builds a working VM image
- Existing build (`Dockerfile`, `build.yml`, `bolt.yml`) unchanged and still works
