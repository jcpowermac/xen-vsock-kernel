#!/bin/bash
# Build the Fedora 44 kernel with CONFIG_XEN_VSOCKETS=y, as plain RPMs.
#
# Method: official F44 src.rpm from the Koji CDN + dnf builddep + rpmbuild,
# with two config changes (vsock core + xen transport built-in) and a release
# bump (200 -> 201) so the result sorts after the stock kernel and coexists
# with it in the same image (stock stays as the boot fallback).
#
# Output: $GITHUB_WORKSPACE/out/*.rpm  (the 5 packages consumers need)
set -euo pipefail

# Pinned Fedora 44 kernel. Bump both when F44 ships a newer kernel.
V=7.2.8
R=200
DIST=fc44
NEWREL=$((R + 1))
KVER="${V}-${NEWREL}.${DIST}"

echo "kernel-version=${KVER}" >> "${GITHUB_OUTPUT:-/dev/null}"
echo "==> building kernel-${KVER} (stock is ${V}-${R}.${DIST})"

# 1. Fetch the official source RPM.
SRPM="kernel-${V}-${R}.${DIST}.src.rpm"
curl -fL --retry 3 -O "https://kojipkgs.fedoraproject.org/packages/kernel/${V}/${R}.${DIST}/src/${SRPM}"
ls -lh "$SRPM"
rpm -i "$SRPM"
cd /root/rpmbuild/SPECS

# 2. Install build dependencies declared by the spec.
dnf -y builddep kernel.spec

# 3. Config: vsock core + xen transport, both built-in (no modprobe anywhere).
CFG=/root/rpmbuild/SOURCES/kernel-x86_64-fedora.config
[ -f "$CFG" ] || { echo "base config missing: $CFG"; ls /root/rpmbuild/SOURCES/ | head; exit 1; }
sed -i 's/^CONFIG_VSOCKETS=m/CONFIG_VSOCKETS=y/' "$CFG"
grep -q '^CONFIG_XEN_VSOCKETS' "$CFG" || echo 'CONFIG_XEN_VSOCKETS=y' >> "$CFG"
grep -E '^CONFIG_(VSOCKETS|XEN_VSOCKETS)=' "$CFG"

# 4. Bump the release so our NEVR differs from Fedora's (same NEVR would be a
#    no-op for the package manager and the module dir would collide).
sed -i "s/^%define specrelease ${R}%/\%define specrelease ${NEWREL}%/" kernel.spec
grep '^%define specrelease' kernel.spec

# 5. Build. --without debuginfo: saves ~3 GB and a chunk of build time on a
#    2-vCPU runner; nothing in our consumers needs the debuginfo.
echo "==> rpmbuild starting ($(nproc) cores)"
rpmbuild -ba --without debuginfo kernel.spec
echo "==> rpmbuild done"

# 6. Verify the config actually took effect in the built tree.
BUILT_CFG=$(find /root/rpmbuild/BUILD -maxdepth 2 -name .config | head -1)
[ -n "$BUILT_CFG" ] || { echo "no built .config found"; exit 1; }
grep -E '^CONFIG_(VSOCKETS|XEN_VSOCKETS)=' "$BUILT_CFG"

# 7. Collect exactly the packages consumers install.
mkdir -p "$GITHUB_WORKSPACE/out"
cd /root/rpmbuild/RPMS/x86_64
for p in kernel kernel-core kernel-modules kernel-modules-core kernel-modules-extra; do
  f="${p}-${KVER}.x86_64.rpm"
  [ -f "$f" ] || { echo "missing expected RPM: $f"; ls | grep "$KVER" || true; exit 1; }
  cp -v "$f" "$GITHUB_WORKSPACE/out/"
done
echo "==> done:"
ls -lh "$GITHUB_WORKSPACE/out/"
