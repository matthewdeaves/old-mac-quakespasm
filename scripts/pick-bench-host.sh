#!/bin/sh
# pick-bench-host.sh - path-stable shim, see scripts/pick-build-host.sh's
# header for why this is a shim and not deleted like bench-evidence.sh etc.
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$SELF_DIR/shared.sh" pick-bench-host.sh "$@"
