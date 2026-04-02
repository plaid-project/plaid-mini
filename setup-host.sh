#!/usr/bin/env bash
set -euo pipefail

TAP_DEV="tap0"
TAP_IP="172.16.0.1"
TAP_MASK="24"
HOST_IFACE=$(ip route | grep default | awk '{print $5}' | head -1)

echo "==> Setting up host networking..."

# Create tap device
if ! ip link show "$TAP_DEV" &>/dev/null; then
    sudo ip tuntap add dev "$TAP_DEV" mode tap
    echo "    Created $TAP_DEV"
else
    echo "    $TAP_DEV already exists"
fi

sudo ip addr replace "${TAP_IP}/${TAP_MASK}" dev "$TAP_DEV"
sudo ip link set "$TAP_DEV" up

# Enable IP forwarding
sudo sysctl -w net.ipv4.ip_forward=1 > /dev/null

# NAT for guest outbound traffic
if ! sudo iptables -t nat -C POSTROUTING -o "$HOST_IFACE" -s 172.16.0.0/24 -j MASQUERADE 2>/dev/null; then
    sudo iptables -t nat -A POSTROUTING -o "$HOST_IFACE" -s 172.16.0.0/24 -j MASQUERADE
    echo "    Added MASQUERADE rule for 172.16.0.0/24 via $HOST_IFACE"
else
    echo "    MASQUERADE rule already exists"
fi

# Allow forwarding
if ! sudo iptables -C FORWARD -i "$TAP_DEV" -o "$HOST_IFACE" -j ACCEPT 2>/dev/null; then
    sudo iptables -A FORWARD -i "$TAP_DEV" -o "$HOST_IFACE" -j ACCEPT
    sudo iptables -A FORWARD -i "$HOST_IFACE" -o "$TAP_DEV" -m state --state RELATED,ESTABLISHED -j ACCEPT
fi

echo "==> Host networking ready. Guest will be at 172.16.0.2"
