#!/usr/bin/env bash
set -euo pipefail

FC_PID_FILE="/tmp/firecracker.pid"
SOCKET_PATH="/tmp/firecracker.sock"

echo "==> Stopping Firecracker..."

if [ -f "$FC_PID_FILE" ]; then
    FC_PID=$(cat "$FC_PID_FILE")
    if kill -0 "$FC_PID" 2>/dev/null; then
        kill "$FC_PID"
        # Wait for it to exit
        for i in $(seq 1 30); do
            if ! kill -0 "$FC_PID" 2>/dev/null; then
                break
            fi
            sleep 0.1
        done
        # Force kill if still running
        if kill -0 "$FC_PID" 2>/dev/null; then
            kill -9 "$FC_PID" 2>/dev/null || true
        fi
        echo "    Firecracker (PID $FC_PID) stopped."
    else
        echo "    Firecracker (PID $FC_PID) not running."
    fi
    rm -f "$FC_PID_FILE"
else
    # Try to find and kill any firecracker process
    pkill -f "firecracker --api-sock" 2>/dev/null || true
    echo "    No PID file found, sent kill to any firecracker process."
fi

rm -f "$SOCKET_PATH"
echo "==> Firecracker stopped."
