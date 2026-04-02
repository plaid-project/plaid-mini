#!/usr/bin/env bash
# Test: verify a cold build can pull sstate from GCS and succeed.
#
# This nukes the local sstate Docker volume, runs `make bill` with
# SSTATE_GCS_BUCKET set, and checks that:
#   1. The sstate cache was pulled from GCS (volume is non-empty)
#   2. The Yocto build succeeded (output tarball exists)
#   3. The Docker image was imported successfully
set -euo pipefail

BUCKET="${SSTATE_GCS_BUCKET:-vpanel-sstate}"
VOLUME="vpanel-base-x86_yocto-sstate"

echo "=== GCS sstate pull test ==="
echo "    Bucket: gs://${BUCKET}/sstate-cache/"
echo "    Volume: ${VOLUME}"
echo ""

# Step 1: Nuke the local sstate volume to simulate a fresh clone
echo "==> Step 1: Removing local sstate volume to simulate cold start..."
docker volume rm "${VOLUME}" 2>/dev/null || true
docker volume create "${VOLUME}"
echo "    Created empty volume ${VOLUME}"

# Verify it's empty
FILE_COUNT=$(docker run --rm -v "${VOLUME}:/sstate" alpine sh -c 'find /sstate -type f | wc -l')
echo "    Files in volume before pull: ${FILE_COUNT}"
if [ "${FILE_COUNT}" -ne 0 ]; then
    echo "FAIL: Volume should be empty but has ${FILE_COUNT} files"
    exit 1
fi

# Step 2: Run the build with GCS pull enabled
echo ""
echo "==> Step 2: Running make bill with SSTATE_GCS_BUCKET=${BUCKET}..."
SSTATE_GCS_BUCKET="${BUCKET}" make bill

# Step 3: Verify sstate was pulled (volume is no longer empty)
echo ""
echo "==> Step 3: Verifying sstate cache was populated from GCS..."
FILE_COUNT=$(docker run --rm -v "${VOLUME}:/sstate" alpine sh -c 'find /sstate -type f | wc -l')
echo "    Files in sstate volume after build: ${FILE_COUNT}"
if [ "${FILE_COUNT}" -lt 100 ]; then
    echo "FAIL: Expected sstate volume to have many files, got ${FILE_COUNT}"
    exit 1
fi
echo "    OK: sstate volume has ${FILE_COUNT} files"

# Step 4: Verify the build output exists
echo ""
echo "==> Step 4: Verifying build output..."
if ls bill/build-output/core-image-minimal-qemux86-64.tar.bz2 >/dev/null 2>&1; then
    echo "    OK: core-image-minimal-qemux86-64.tar.bz2 exists"
elif ls bill/build-output/core-image-minimal-qemux86-64.rootfs.tar.bz2 >/dev/null 2>&1; then
    echo "    OK: core-image-minimal-qemux86-64.rootfs.tar.bz2 exists"
else
    echo "FAIL: No build output tarball found"
    exit 1
fi

# Step 5: Verify Docker image was imported
echo ""
echo "==> Step 5: Verifying vpanel-bill:latest Docker image..."
if docker image inspect vpanel-bill:latest >/dev/null 2>&1; then
    echo "    OK: vpanel-bill:latest exists"
else
    echo "FAIL: vpanel-bill:latest not found"
    exit 1
fi

echo ""
echo "=== ALL TESTS PASSED ==="
echo "    GCS sstate pull works for cold builds."
