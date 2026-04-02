#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "==> Building Bill (Yocto Zeus core-image-minimal with Python 3.7)..."
echo "    This uses sstate cache, so rebuilds should be fast."

# Copy build-inner.sh into the context so the container can run it
docker compose run --rm builder

echo "==> Build complete."
echo "    Run ./import.sh to import as vpanel-bill:latest"
