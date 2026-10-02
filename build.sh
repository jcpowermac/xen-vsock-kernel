#!/bin/bash
# Host-side driver (GitHub Actions runner). Not run inside the container.
#
# Pulls (or builds) the toolchain image and runs the in-container build,
# which always builds the CURRENT Fedora kernel from the repo (no pinning).
#
# Env in:  IMG (optional) — toolchain image
# Env out: GITHUB_OUTPUT kernel-version
set -euo pipefail

IMG="${IMG:-ghcr.io/jcpowermac/xen-vsock-kernel-build:latest}"
echo "==> using build image $IMG"
docker pull "$IMG" 2>/dev/null \
  || { echo "build image not found, building it"; docker build -t "$IMG" "$GITHUB_WORKSPACE"; }

docker run --rm \
  -v "$GITHUB_WORKSPACE:/github/workspace" \
  -w /github/workspace \
  "$IMG" bash /github/workspace/build-container.sh

KVER=$(cat "$GITHUB_WORKSPACE/kernel_version.txt")
echo "kernel-version=${KVER}" >> "${GITHUB_OUTPUT:-/dev/null}"
echo "==> built kernel-${KVER}"
