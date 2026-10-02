#!/bin/bash
# In-container kernel build (runs in the ghcr toolchain image via build.sh).
#
# No pinning: dnf resolves the CURRENT Fedora kernel from the repo
# (equivalent to what `dnf update kernel` would install), we patch two
# config lines (vsock core + xen transport built-in) and bump the release
# +1, so the result sorts after the stock kernel and coexists with it in
# the same image (stock stays as the boot fallback).
#
# Output: /github/workspace/out/*.rpm + /github/workspace/kernel_version.txt
set -euo pipefail

TOPDIR=/root/rpmbuild
DEFINE=(--define "_topdir $TOPDIR")
mkdir -p "$TOPDIR" /tmp/src

# 1. Fetch the current kernel source RPM from the repo.
dnf -y download --source --destdir /tmp/src kernel
SRPM=$(ls /tmp/src/kernel-*.src.rpm | head -1)
[ -n "$SRPM" ] || { echo "no kernel src.rpm downloaded"; ls /tmp/src; exit 1; }

# 2. Derive V-R from the downloaded name: kernel-7.2.8-200.fc44.src.rpm
NVR=$(basename "$SRPM"); NVR=${NVR#kernel-}; NVR=${NVR%.src.rpm}
V=${NVR%%-*}
R=${NVR#*-}; R=${R%%.*}
NEWREL=$((R + 1))
KVER="${V}-${NEWREL}.fc44"
echo "$KVER" > /github/workspace/kernel_version.txt
echo "==> stock kernel is ${NVR}, building kernel-${KVER}"

# 3. Extract the src.rpm into the topdir.
rpm "${DEFINE[@]}" -i "$SRPM"
cd "$TOPDIR/SPECS"

# 4. Install build dependencies declared by the spec.
dnf -y builddep kernel.spec

# 5. Config: vsock core + xen transport, both built-in (no modprobe anywhere).
CFG="$TOPDIR/SOURCES/kernel-x86_64-fedora.config"
[ -f "$CFG" ] || { echo "base config missing: $CFG"; ls "$TOPDIR/SOURCES/" | head; exit 1; }
sed -i 's/^CONFIG_VSOCKETS=m/CONFIG_VSOCKETS=y/' "$CFG"
grep -q '^CONFIG_XEN_VSOCKETS' "$CFG" || echo 'CONFIG_XEN_VSOCKETS=y' >> "$CFG"
grep -E '^CONFIG_(VSOCKETS|XEN_VSOCKETS)=' "$CFG"

# 6. Bump the release so our NEVR differs from Fedora's (same NEVR would be a
#    no-op for the package manager and the module dir would collide).
sed -i "s/^%define specrelease ${R}%/\%define specrelease ${NEWREL}%/" kernel.spec
grep '^%define specrelease' kernel.spec

# 7. Build. --without debuginfo: saves ~3 GB and a chunk of build time on a
#    2-vCPU runner; nothing in our consumers needs the debuginfo.
echo "==> rpmbuild starting ($(nproc) cores)"
rpmbuild "${DEFINE[@]}" -ba --without debuginfo kernel.spec
echo "==> rpmbuild done"

# 8. Verify the config actually took effect in the built tree.
BUILT_CFG=$(find "$TOPDIR/BUILD" -maxdepth 2 -name .config | head -1)
[ -n "$BUILT_CFG" ] || { echo "no built .config found"; exit 1; }
grep -E '^CONFIG_(VSOCKETS|XEN_VSOCKETS)=' "$BUILT_CFG"

# 9. Collect exactly the packages consumers install.
mkdir -p /github/workspace/out
cd "$TOPDIR/RPMS/x86_64"
for p in kernel kernel-core kernel-modules kernel-modules-core kernel-modules-extra; do
  f="${p}-${KVER}.x86_64.rpm"
  [ -f "$f" ] || { echo "missing expected RPM: $f"; ls | grep "$KVER" || true; exit 1; }
  cp -v "$f" /github/workspace/out/
done
echo "==> done:"
ls -lh /github/workspace/out/
