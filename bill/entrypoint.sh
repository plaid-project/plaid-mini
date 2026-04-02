#!/usr/bin/env bash
set -euo pipefail

# Fix ownership of /build directory (volume mount may be root-owned)
chown -R builder:builder /build 2>/dev/null || true

# Drop to builder user and exec the command
exec gosu builder "$@"
