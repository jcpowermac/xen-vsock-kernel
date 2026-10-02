# Three stages, two cache domains (buildx + GHA layer cache; see
# .github/workflows/build.yml):
#
#   builder — toolchain + kernel build deps. Layer-cached across runs; bump
#             the `build_deps` dispatch input to force a refresh when a new
#             kernel wants deps this stage lacks (rare — the kernel stage
#             re-runs `dnf builddep` incrementally anyway).
#   kernel  — the CURRENT Fedora kernel, re-resolved from the repo on every
#             build (no pinning), + our delta: vsock core and Xen transport
#             built-in, release +1 (NEVR sorts after stock, coexists with
#             it), x86-64-v4 ISA target. Always re-runs.
#   build   — rpmbuild + collect. Always re-runs (the ~1-2 h part).

FROM quay.io/fedora/fedora:44 AS builder
ARG BUILD_DEPS=""
RUN set -eux \
 && echo "builder refresh: ${BUILD_DEPS}" \
 && dnf -y install \
        dnf-plugins-core \
        rpm-build \
        rpmdevtools \
        cpio \
        tar \
        xz \
        git \
        perl \
        which \
 && dnf -y download --source --destdir /src kernel \
 && rpm -i /src/kernel-*.src.rpm \
 && dnf -y builddep /root/rpmbuild/SPECS/kernel.spec \
 && dnf clean all \
 && rm -rf /src /root/rpmbuild

FROM builder AS kernel
ARG FORCE_REFRESH=""
RUN set -eux \
 && echo "kernel refresh: ${FORCE_REFRESH}" \
 && dnf -y download --source --destdir /src kernel \
 && rpm -i /src/kernel-*.src.rpm \
 && dnf -y builddep /root/rpmbuild/SPECS/kernel.spec \
 && dnf clean all \
 && rm -rf /src \
 && cd /root/rpmbuild/SPECS \
 && CFG=/root/rpmbuild/SOURCES/kernel-x86_64-fedora.config \
 && sed -i 's/^CONFIG_VSOCKETS=m/CONFIG_VSOCKETS=y/' "$CFG" \
 && (grep -q '^CONFIG_XEN_VSOCKETS' "$CFG" || echo 'CONFIG_XEN_VSOCKETS=y' >> "$CFG") \
 && grep -E '^CONFIG_(VSOCKETS|XEN_VSOCKETS)=' "$CFG" \
 && R=$(awk '/^%define specrelease /{print $3; exit}' kernel.spec) \
 && R=${R%%[!0-9]*} \
 && sed -i "s/^%define specrelease ${R}%/\%define specrelease $((R + 1))%/" kernel.spec \
 && grep '^%define specrelease' kernel.spec \
 && sed -i 's|^%define make %{__make} %{?cross_opts} %{?make_opts} HOSTCFLAGS=|%define make %{__make} %{?cross_opts} %{?make_opts} ISA_LEVEL=4 HOSTCFLAGS=|' kernel.spec \
 && grep -n 'ISA_LEVEL=4' kernel.spec

FROM kernel AS build
RUN set -eux \
 && cd /root/rpmbuild/SPECS \
 && rpmbuild -ba --without debuginfo kernel.spec \
 && grep -E '^CONFIG_(VSOCKETS|XEN_VSOCKETS)=' /root/rpmbuild/BUILD/linux-*/.config \
 && cd /root/rpmbuild/RPMS/x86_64 \
 && KVER=$(ls kernel-core-*.x86_64.rpm | head -1 | sed 's/^kernel-core-//; s/\.x86_64\.rpm$//') \
 && echo "$KVER" > /tmp/kernel_version.txt \
 && mkdir -p /out \
 && for p in kernel kernel-core kernel-modules kernel-modules-core kernel-modules-extra; do \
        cp "${p}-${KVER}.x86_64.rpm" /out/; \
    done \
 && cp /tmp/kernel_version.txt /out/ \
 && rm -rf /root/rpmbuild/BUILD \
 && ls -lh /out/
