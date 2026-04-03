#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOCKET_PATH="/tmp/firecracker.sock"
FC_BIN="$SCRIPT_DIR/assets/firecracker"
KERNEL_PATH="$SCRIPT_DIR/assets/vmlinux"
ROOTFS_PATH="$SCRIPT_DIR/assets/alpine-rootfs.ext4"
FC_PID_FILE="/tmp/firecracker.pid"

# Validate assets
for f in "$FC_BIN" "$KERNEL_PATH" "$ROOTFS_PATH"; do
    if [ ! -f "$f" ]; then
        echo "ERROR: Missing $f"
        exit 1
    fi
done

# Clean up stale socket
rm -f "$SOCKET_PATH"

echo "==> Starting Firecracker..."

# Start Firecracker in background
"$FC_BIN" --api-sock "$SOCKET_PATH" &
FC_PID=$!
echo $FC_PID > "$FC_PID_FILE"

# Wait for API socket to appear
for i in $(seq 1 20); do
    if [ -e "$SOCKET_PATH" ]; then
        break
    fi
    sleep 0.1
done

if [ ! -e "$SOCKET_PATH" ]; then
    echo "ERROR: Firecracker API socket did not appear"
    kill $FC_PID 2>/dev/null || true
    exit 1
fi

echo "    Firecracker PID: $FC_PID"

# Configure boot source
echo "    Setting boot source..."
curl -s --unix-socket "$SOCKET_PATH" -X PUT "http://localhost/boot-source" \
    -H "Content-Type: application/json" \
    -d "{
        \"kernel_image_path\": \"$KERNEL_PATH\",
        \"boot_args\": \"console=ttyS0 reboot=k panic=1 pci=off root=/dev/vda rw init=/sbin/init\"
    }"

# Configure rootfs drive
echo "    Setting rootfs drive..."
curl -s --unix-socket "$SOCKET_PATH" -X PUT "http://localhost/drives/rootfs" \
    -H "Content-Type: application/json" \
    -d "{
        \"drive_id\": \"rootfs\",
        \"path_on_host\": \"$ROOTFS_PATH\",
        \"is_root_device\": true,
        \"is_read_only\": false
    }"

# Configure network interface
echo "    Setting network interface..."
curl -s --unix-socket "$SOCKET_PATH" -X PUT "http://localhost/network-interfaces/eth0" \
    -H "Content-Type: application/json" \
    -d '{
        "iface_id": "eth0",
        "guest_mac": "AA:FC:00:00:00:01",
        "host_dev_name": "tap0"
    }'

# Configure machine
echo "    Setting machine config..."
curl -s --unix-socket "$SOCKET_PATH" -X PUT "http://localhost/machine-config" \
    -H "Content-Type: application/json" \
    -d '{
        "vcpu_count": 2,
        "mem_size_mib": 2048
    }'

# Start the VM
echo "    Starting VM..."
curl -s --unix-socket "$SOCKET_PATH" -X PUT "http://localhost/actions" \
    -H "Content-Type: application/json" \
    -d '{"action_type": "InstanceStart"}'

echo "==> Firecracker VM started (PID: $FC_PID)"
echo "    Guest IP: 172.16.0.2"
