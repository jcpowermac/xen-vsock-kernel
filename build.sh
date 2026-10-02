#!/bin/bash
# Host-side driver (GitHub Actions runner). Not run inside the container.
#
# Validates the requested kernel, fails fast if the src.rpm is not on the
# Koji CDN, pulls (or builds) the toolchain image, and runs the in-container
# build against the workspace.
#
# Env in:  KVER_INPUT = stock version-release (e.g. "7.2.8-200"), IMG (opt.)
# Env out: GITHUB_OUTPUT kernel-version, $GITHUB_WORKSPACE/kernel_version.txt
set -euo pipefail

# Stock base is "V-R" (the stock NEVR without the .dist); we build "V-(R+1)".
KIN="${KVER_INPUT:-7.2.8-200}"
V="${KIN%%-*}"
R="${KIN#*-}"
DIST=fc44
NEWREL=$((R + 1))
KVER="${V}-${NEWREL}.${DIST}"
IMG="${IMG:-ghcr.io/jcpowermac/xen-vsock-kernel-build:latest}"

case "$V" in *.*.*) ;; *) echo "bad kernel version: $V"; exit 1;; esac
case "$R" in (*[!0-9]*|'') echo "bad release: $R"; exit 1;; esac

URL="https://kojipkgs.fedoraproject.org/packages/kernel/${V}/${R}.${DIST}/src/kernel-${V}-${R}.${DIST}.src.rpm"
# Fail in seconds, not an hour, if that kernel version is not on the CDN.
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 -r 0-0 "$URL" || true)
case "$code" in 200|206) ;; *) echo "SRPM preflight failed (http $code): $URL"; exit 1;; esac

echo "kernel-version=${KVER}" >> "${GITHUB_OUTPUT:-/dev/null}"
echo "==> building kernel-${KVER} (stock is ${V}-${R}.${DIST}) in $IMG"

docker pull "$IMG" 2>/dev/null \
  || { echo "build image not found, building it"; docker build -t "$IMG" "$GITHUB_WORKSPACE"; }

docker run --rm \
  -v "$GITHUB_WORKSPACE:/github/workspace" \
  -w /github/workspace \
  -e KVER_INPUT="$V" \
  -e KREL_INPUT="$R" \
  -e GITHUB_WORKSPACE="/github/workspace" \
  "$IMG" bash /github/workspace/build-container.sh
