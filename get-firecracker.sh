#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSETS_DIR="$SCRIPT_DIR/assets"
FC_VERSION="v1.15.0"
ARCH="x86_64"

mkdir -p "$ASSETS_DIR"

# Download Firecracker binary
FC_URL="https://github.com/firecracker-microvm/firecracker/releases/download/${FC_VERSION}/firecracker-${FC_VERSION}-${ARCH}.tgz"

if [ ! -f "$ASSETS_DIR/firecracker" ]; then
    echo "==> Downloading Firecracker ${FC_VERSION}..."
    curl -fSL "$FC_URL" -o "/tmp/firecracker.tgz"
    tar -xzf /tmp/firecracker.tgz -C /tmp/
    cp "/tmp/release-${FC_VERSION}-${ARCH}/firecracker-${FC_VERSION}-${ARCH}" "$ASSETS_DIR/firecracker"
    chmod +x "$ASSETS_DIR/firecracker"
    rm -rf /tmp/firecracker.tgz "/tmp/release-${FC_VERSION}-${ARCH}"
    echo "    Firecracker installed: $ASSETS_DIR/firecracker"
else
    echo "==> Firecracker already present."
fi

# Download prebuilt vmlinux kernel (stopgap until custom kernel build)
# Firecracker publishes CI kernels in their S3 bucket
KERNEL_URL="https://s3.amazonaws.com/spec.ccfc.min/firecracker-ci/v1.15/${ARCH}/vmlinux-5.10.245"

if [ ! -f "$ASSETS_DIR/vmlinux" ]; then
    echo "==> Downloading prebuilt vmlinux kernel..."
    curl -fSL "$KERNEL_URL" -o "$ASSETS_DIR/vmlinux"
    echo "    Kernel installed: $ASSETS_DIR/vmlinux"
else
    echo "==> Kernel already present."
fi
