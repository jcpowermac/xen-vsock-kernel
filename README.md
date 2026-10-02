# xen-vsock-kernel

Fedora 44 kernel RPMs with `CONFIG_XEN_VSOCKETS=y`.

Stock F44 kernels build vsock as a module and leave the Xen transport
off, so Xen guests and their dom0 have no vsock channel at all. This repo
builds the official F44 kernel with the vsock core and the Xen transport
built in (`CONFIG_VSOCKETS=y`, `CONFIG_XEN_VSOCKETS=y`). The built kernel
is what `qlvm`'s `vm run --connect vsock` waypipe channel needs on both
ends (guest image and dom0).

## The build

The `Dockerfile` is the whole build: it installs the rpmbuild toolchain,
fetches **whatever kernel the Fedora 44 repo currently serves** (no
pinning — like `dnf update kernel`), applies our delta (two vsock config
lines + release bumped +1 so `7.2.8-201.fc44` sorts after the stock
`7.2.8-200.fc44` and both coexist in the same image), and compiles.
`build.yml` just runs `docker build` and copies the five RPMs out.

## Building

Dispatch Actions → `build` (no inputs). When Fedora ships a newer kernel,
just re-dispatch — rebuilding the container picks up the new kernel.
The build takes ~1-2 h (2-vCPU runner).

On success, the five consumer packages land as a GitHub release tagged
`kernel-<built-NEVR>`: `kernel`, `kernel-core`, `kernel-modules`,
`kernel-modules-core`, `kernel-modules-extra`.

## Consuming (blue-build recipes)

Install the release assets by URL with the `dnf` module — no yum repo,
no signing keys (unsigned build, consumed only by our own image builds):

```yaml
  - type: dnf
    install:
      packages:
        - https://github.com/jcpowermac/xen-vsock-kernel/releases/download/kernel-7.2.8-201.fc44/kernel-7.2.8-201.fc44.x86_64.rpm
        - https://github.com/jcpowermac/xen-vsock-kernel/releases/download/kernel-7.2.8-201.fc44/kernel-core-7.2.8-201.fc44.x86_64.rpm
        - https://github.com/jcpowermac/xen-vsock-kernel/releases/download/kernel-7.2.8-201.fc44/kernel-modules-7.2.8-201.fc44.x86_64.rpm
        - https://github.com/jcpowermac/xen-vsock-kernel/releases/download/kernel-7.2.8-201.fc44/kernel-modules-core-7.2.8-201.fc44.x86_64.rpm
        # dom0 only (r8169 uplink driver lives in modules-extra):
        - https://github.com/jcpowermac/xen-vsock-kernel/releases/download/kernel-7.2.8-201.fc44/kernel-modules-extra-7.2.8-201.fc44.x86_64.rpm
```

- Guest images (`bolt.yml`): the first four are enough (netfront/blkfront
  are in modules-core).
- Dom0 (`recipe.yml`): include `kernel-modules-extra` too — the dom0's
  uplink is an r8169 Realtek NIC, which ships in that subpackage.
