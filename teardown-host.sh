#!/usr/bin/env bash
set -euo pipefail

TAP_DEV="tap0"
HOST_IFACE=$(ip route | grep default | awk '{print $5}' | head -1)

echo "==> Tearing down host networking..."

# Remove iptables rules
sudo iptables -t nat -D POSTROUTING -o "$HOST_IFACE" -s 172.16.0.0/24 -j MASQUERADE 2>/dev/null || true
sudo iptables -D FORWARD -i "$TAP_DEV" -o "$HOST_IFACE" -j ACCEPT 2>/dev/null || true
sudo iptables -D FORWARD -i "$HOST_IFACE" -o "$TAP_DEV" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true

# Remove tap device
if ip link show "$TAP_DEV" &>/dev/null; then
    sudo ip link set "$TAP_DEV" down
    sudo ip tuntap del dev "$TAP_DEV" mode tap
    echo "    Removed $TAP_DEV"
else
    echo "    $TAP_DEV not found"
fi

echo "==> Host networking cleaned up."
