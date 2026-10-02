# xen-vsock-kernel

Fedora 44 kernel RPMs with `CONFIG_XEN_VSOCKETS=y`.

Stock F44 kernels build vsock as a module and leave the Xen transport
off, so Xen guests and their dom0 have no vsock channel at all. This repo
builds the official F44 kernel with the vsock core and the Xen transport
built in (`CONFIG_VSOCKETS=y`, `CONFIG_XEN_VSOCKETS=y`). The built kernel
is what `qlvm`'s `vm run --connect vsock` waypipe channel needs on both
ends (guest image and dom0).

## Layout

- `Dockerfile` — fedora:44 build toolchain image (no kernel sources).
  `build-image.yml` pushes it to `ghcr.io/jcpowermac/xen-vsock-kernel-build`
  (on Dockerfile changes, or on demand), so kernel builds don't reinstall
  the toolchain every time.
- `build.sh` — host-side driver (GHA runner): validates the requested
  kernel, fails fast if the src.rpm is not on the Koji CDN, pulls the
  toolchain image, runs the container build.
- `build-container.sh` — in-container build: official src.rpm from the
  Koji CDN, `dnf builddep`, two config lines patched, release bumped
  `R -> R+1` (so `7.2.8-201.fc44` sorts after the stock `7.2.8-200.fc44`
  and both coexist in the same image), `rpmbuild -ba --without debuginfo`.
- `.github/workflows/build.yml` — the kernel build (manual dispatch).
- `.github/workflows/build-image.yml` — toolchain image build/push.

## Building

Dispatch Actions → `build`, entering the **stock** kernel
version-release to base the build on (default `7.2.8-200`). The result is
`V-(R+1)` — e.g. input `7.2.8-200` produces `kernel-7.2.8-201.fc44`.

When Fedora ships a newer F44 kernel, dispatch with the new stock version
(e.g. `7.2.9-200`) — no commit needed. The build takes ~1-2 h on a
2-vCPU runner.

On success, the five consumer packages land as a GitHub release tagged
`kernel-<V-R+1>.fc44`: `kernel`, `kernel-core`, `kernel-modules`,
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
