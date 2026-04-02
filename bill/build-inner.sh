#!/usr/bin/env bash
set -eo pipefail

cd /build

# GitHub killed git:// protocol — redirect to https
git config --global url."https://".insteadOf git://

# Pull sstate cache from GCS if bucket is configured
if [ -n "${SSTATE_GCS_BUCKET:-}" ]; then
    echo "==> Pulling sstate cache from gs://${SSTATE_GCS_BUCKET}/sstate-cache/ ..."
    gsutil -m rsync -r "gs://${SSTATE_GCS_BUCKET}/sstate-cache/" /yocto/sstate-cache/ || \
        echo "    Warning: GCS pull failed (bucket may be empty on first run), continuing..."
fi

# Clone poky if not already present (pinned to match sstate cache)
if [ ! -d poky ]; then
    git clone -b yocto-3.0.3 https://git.yoctoproject.org/poky.git poky
fi

# The git:// protocol is dead on GitHub — git config insteadOf handles that.
# Do NOT blindly replace branch=master with branch=main; most repos still use master.

# Copy conf files into the build directory
mkdir -p /build/build/conf
cp /build/conf/local.conf /build/build/conf/local.conf
cp /build/conf/bblayers.conf /build/build/conf/bblayers.conf

# Source the oe-init-build-env (this changes directory to /build/build)
source /build/poky/oe-init-build-env /build/build

# Build
bitbake core-image-minimal

# Copy the output rootfs tarball
mkdir -p /build/build-output
cp /build/build/tmp/deploy/images/qemux86-64/core-image-minimal-qemux86-64.tar.bz2 \
   /build/build-output/ 2>/dev/null || \
cp /build/build/tmp/deploy/images/qemux86-64/core-image-minimal-qemux86-64.rootfs.tar.bz2 \
   /build/build-output/ 2>/dev/null || true

# Also copy any tar.gz variant
cp /build/build/tmp/deploy/images/qemux86-64/core-image-minimal-qemux86-64.tar.gz \
   /build/build-output/ 2>/dev/null || true

# Push sstate cache to GCS if bucket is configured
if [ -n "${SSTATE_GCS_BUCKET:-}" ]; then
    echo "==> Pushing sstate cache to gs://${SSTATE_GCS_BUCKET}/sstate-cache/ ..."
    gsutil -m rsync -r /yocto/sstate-cache/ "gs://${SSTATE_GCS_BUCKET}/sstate-cache/" || \
        echo "    Warning: GCS push failed, continuing..."
fi

echo "Build complete. Output in /build/build-output/"
ls -la /build/build-output/
