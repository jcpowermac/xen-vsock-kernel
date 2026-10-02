FROM quay.io/fedora/fedora:44

# Build toolchain for rpmbuild'ing the Fedora kernel outside koji.
# `dnf builddep kernel.spec` (run in build.sh) installs the rest.
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

COPY build.sh /build.sh
RUN chmod +x /build.sh
