#!/bin/bash
# In-container kernel build (runs in the ghcr toolchain image via build.sh).
#
# Method: official src.rpm from the Koji CDN + dnf builddep + rpmbuild, with
# two config changes (vsock core + xen transport built-in) and a release bump
# (R -> R+1) so the result sorts after the stock kernel and coexists with it
# in the same image (stock stays as the boot fallback).
#
# Output: /github/workspace/out/*.rpm  (the 5 packages consumers need)
set -euo pipefail

V="${KVER_INPUT:?KVER_INPUT not set}"
R="${KREL_INPUT:?KREL_INPUT not set}"
DIST=fc44
NEWREL=$((R + 1))
KVER="${V}-${NEWREL}.${DIST}"

# rpm's default _topdir is not where we want it; pin it explicitly.
TOPDIR=/root/rpmbuild
DEFINE="--define _topdir ${TOPDIR}"
mkdir -p "$TOPDIR"

# 1. Fetch the official source RPM and extract it.
SRPM="kernel-${V}-${R}.${DIST}.src.rpm"
curl -fL --retry 3 -O "https://kojipkgs.fedoraproject.org/packages/kernel/${V}/${R}.${DIST}/src/${SRPM}"
ls -lh "$SRPM"
rpm $DEFINE -i "$SRPM"
cd "$TOPDIR/SPECS"

# 2. Install build dependencies declared by the spec.
dnf -y builddep kernel.spec

# 3. Config: vsock core + xen transport, both built-in (no modprobe anywhere).
CFG="$TOPDIR/SOURCES/kernel-x86_64-fedora.config"
[ -f "$CFG" ] || { echo "base config missing: $CFG"; ls "$TOPDIR/SOURCES/" | head; exit 1; }
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
rpmbuild $DEFINE -ba --without debuginfo kernel.spec
echo "==> rpmbuild done"

# 6. Verify the config actually took effect in the built tree.
BUILT_CFG=$(find "$TOPDIR/BUILD" -maxdepth 2 -name .config | head -1)
[ -n "$BUILT_CFG" ] || { echo "no built .config found"; exit 1; }
grep -E '^CONFIG_(VSOCKETS|XEN_VSOCKETS)=' "$BUILT_CFG"

# 7. Collect exactly the packages consumers install.
mkdir -p /github/workspace/out
cd "$TOPDIR/RPMS/x86_64"
for p in kernel kernel-core kernel-modules kernel-modules-core kernel-modules-extra; do
  f="${p}-${KVER}.x86_64.rpm"
  [ -f "$f" ] || { echo "missing expected RPM: $f"; ls | grep "$KVER" || true; exit 1; }
  cp -v "$f" /github/workspace/out/
done
echo "==> done:"
ls -lh /github/workspace/out/
