#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Find the rootfs tarball
TARBALL=""
for f in build-output/core-image-minimal-qemux86-64.tar.bz2 \
         build-output/core-image-minimal-qemux86-64.rootfs.tar.bz2 \
         build-output/core-image-minimal-qemux86-64.tar.gz; do
    if [ -f "$f" ]; then
        TARBALL="$f"
        break
    fi
done

if [ -z "$TARBALL" ]; then
    echo "ERROR: No rootfs tarball found in build-output/"
    echo "       Run ./build.sh first."
    exit 1
fi

echo "==> Importing $TARBALL as vpanel-bill:latest..."

# Remove old image if it exists
docker rmi vpanel-bill:latest 2>/dev/null || true

# Import
docker import "$TARBALL" vpanel-bill:latest

echo "==> Verifying python3..."
docker run --rm vpanel-bill:latest /usr/bin/python3 --version

echo "==> Done. vpanel-bill:latest is ready."
