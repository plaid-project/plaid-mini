#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUEST_IP="172.16.0.2"
SSH_KEY="$SCRIPT_DIR/keys/rg_key"
MAX_WAIT=60
INTERVAL=2

echo "==> Waiting for SSH on $GUEST_IP (up to ${MAX_WAIT}s)..."

elapsed=0
while [ $elapsed -lt $MAX_WAIT ]; do
    if ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
       -o ConnectTimeout=2 -o BatchMode=yes \
       root@"$GUEST_IP" "echo ok" 2>/dev/null; then
        echo "==> SSH is ready."
        exit 0
    fi
    sleep $INTERVAL
    elapsed=$((elapsed + INTERVAL))
    echo "    Waiting... (${elapsed}s)"
done

echo "ERROR: SSH did not become available within ${MAX_WAIT}s"
exit 1
