#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ROOTFS_IMG="$PROJECT_DIR/assets/alpine-rootfs.ext4"
KEYS_DIR="$PROJECT_DIR/keys"
ROOTFS_SIZE_MB=2048
MOUNT_DIR="/tmp/alpine-rootfs-mount"

echo "==> Building Alpine rootfs for Firecracker guest (Red Green)..."

# Step 1: Generate SSH keypair if not present
mkdir -p "$KEYS_DIR"
if [ ! -f "$KEYS_DIR/rg_key" ]; then
    echo "    Generating SSH keypair..."
    ssh-keygen -t ed25519 -f "$KEYS_DIR/rg_key" -N "" -C "plaid-redgreen"
    chmod 600 "$KEYS_DIR/rg_key"
    chmod 644 "$KEYS_DIR/rg_key.pub"
else
    echo "    SSH keypair already exists."
fi

# Step 2: Build the Docker image
echo "    Building Docker image..."
docker build -t alpine-rootfs-builder -f "$SCRIPT_DIR/Dockerfile.rootfs" "$SCRIPT_DIR"

# Step 3: Create ext4 image
echo "    Creating ${ROOTFS_SIZE_MB}MB ext4 image..."
mkdir -p "$PROJECT_DIR/assets"
dd if=/dev/zero of="$ROOTFS_IMG" bs=1M count=$ROOTFS_SIZE_MB status=progress
mkfs.ext4 -F "$ROOTFS_IMG"

# Step 4: Mount and populate
echo "    Mounting and populating rootfs (needs sudo)..."
sudo mkdir -p "$MOUNT_DIR"
sudo mount -o loop "$ROOTFS_IMG" "$MOUNT_DIR"

# Export the Docker image filesystem
CONTAINER_ID=$(docker create alpine-rootfs-builder)
docker export "$CONTAINER_ID" | sudo tar -xf - -C "$MOUNT_DIR"
docker rm "$CONTAINER_ID" > /dev/null

# Write resolv.conf (can't do this in Dockerfile - Docker mounts it)
sudo bash -c "echo 'nameserver 8.8.8.8' > '$MOUNT_DIR/etc/resolv.conf'"

# Inject SSH public key
sudo mkdir -p "$MOUNT_DIR/root/.ssh"
sudo chmod 700 "$MOUNT_DIR/root/.ssh"
sudo cp "$KEYS_DIR/rg_key.pub" "$MOUNT_DIR/root/.ssh/authorized_keys"
sudo chmod 600 "$MOUNT_DIR/root/.ssh/authorized_keys"

# Create device nodes needed for boot
sudo mknod -m 622 "$MOUNT_DIR/dev/console" c 5 1 2>/dev/null || true
sudo mknod -m 666 "$MOUNT_DIR/dev/null"    c 1 3 2>/dev/null || true
sudo mknod -m 666 "$MOUNT_DIR/dev/zero"    c 1 5 2>/dev/null || true
sudo mknod -m 666 "$MOUNT_DIR/dev/tty"     c 5 0 2>/dev/null || true
sudo mknod -m 666 "$MOUNT_DIR/dev/ttyS0"   c 4 64 2>/dev/null || true
sudo mknod -m 666 "$MOUNT_DIR/dev/random"  c 1 8 2>/dev/null || true
sudo mknod -m 666 "$MOUNT_DIR/dev/urandom" c 1 9 2>/dev/null || true

# Create init symlink if needed (OpenRC)
if [ ! -f "$MOUNT_DIR/sbin/init" ]; then
    sudo ln -sf /sbin/openrc-init "$MOUNT_DIR/sbin/init" 2>/dev/null || true
fi

# Ensure /etc/init.d/networking uses OpenRC properly
# Write a simple rcS init script as fallback
sudo tee "$MOUNT_DIR/etc/init.d/rcS.local" > /dev/null << 'INITEOF'
#!/bin/sh
# Bring up networking if OpenRC hasn't
if ! ip addr show eth0 | grep -q "172.16.0.2"; then
    ip addr add 172.16.0.2/24 dev eth0
    ip link set eth0 up
    ip route add default via 172.16.0.1
fi
# Start sshd if not running
if ! pgrep sshd > /dev/null; then
    /usr/sbin/sshd
fi
INITEOF
sudo chmod +x "$MOUNT_DIR/etc/init.d/rcS.local"

# Unmount
sudo umount "$MOUNT_DIR"
sudo rmdir "$MOUNT_DIR"

echo "==> Alpine rootfs created: $ROOTFS_IMG"
echo "    SSH key: $KEYS_DIR/rg_key"
