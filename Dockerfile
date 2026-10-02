FROM quay.io/fedora/fedora:44

# Toolchain for rpmbuild'ing the Fedora kernel outside koji.
RUN dnf -y install \
        dnf-plugins-core \
        rpm-build \
        rpmdevtools \
        cpio \
        tar \
        xz \
        git \
        perl \
        which \
      && dnf clean all

# The current F44 kernel: src.rpm + build deps. There is NO pinning —
# rebuilding this image IS the kernel-version bump (whatever the repo
# serves at build time, like `dnf update kernel`).
RUN dnf -y download --source --destdir /src kernel \
 && rpm -i /src/kernel-*.src.rpm \
 && dnf -y builddep /root/rpmbuild/SPECS/kernel.spec \
 && dnf clean all \
 && rm -rf /src

# Our delta vs Fedora: vsock core + xen transport built-in, and the release
# bumped +1 so the NEVR differs from Fedora's and the built kernel sorts
# after the stock one (both coexist; stock stays the boot fallback).
RUN set -eux \
 && CFG=/root/rpmbuild/SOURCES/kernel-x86_64-fedora.config \
 && sed -i 's/^CONFIG_VSOCKETS=m/CONFIG_VSOCKETS=y/' "$CFG" \
 && (grep -q '^CONFIG_XEN_VSOCKETS' "$CFG" || echo 'CONFIG_XEN_VSOCKETS=y' >> "$CFG") \
 && grep -E '^CONFIG_(VSOCKETS|XEN_VSOCKETS)=' "$CFG" \
 && R=$(awk '/^%define specrelease /{print $3; exit}' /root/rpmbuild/SPECS/kernel.spec) \
 && R=${R%%[!0-9]*} \
 && sed -i "s/^%define specrelease ${R}%/\%define specrelease $((R + 1))%/" /root/rpmbuild/SPECS/kernel.spec \
 && grep '^%define specrelease' /root/rpmbuild/SPECS/kernel.spec

# The long part: ~1-2 h on a 2-vCPU GHA runner. --without debuginfo saves
# ~3 GB and build time; nothing in our consumers needs it.
RUN rpmbuild -ba --without debuginfo /root/rpmbuild/SPECS/kernel.spec

# Verify, collect the five packages consumers install, drop the build tree.
RUN set -eux \
 && grep -E '^CONFIG_(VSOCKETS|XEN_VSOCKETS)=' /root/rpmbuild/BUILD/linux-*/.config \
 && cd /root/rpmbuild/RPMS/x86_64 \
 && KVER=$(ls kernel-core-*.x86_64.rpm | head -1 | sed 's/^kernel-core-//; s/\.x86_64\.rpm$//') \
 && echo "$KVER" > /tmp/kernel_version.txt \
 && mkdir -p /out \
 && for p in kernel kernel-core kernel-modules kernel-modules-core kernel-modules-extra; do \
        cp "${p}-${KVER}.x86_64.rpm" /out/; \
    done \
 && cp /tmp/kernel_version.txt /out/ \
 && rm -rf /root/rpmbuild/BUILD /src \
 && ls -lh /out/
