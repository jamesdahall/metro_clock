#!/usr/bin/env bash
set -euo pipefail

# Convenience wrapper retained for compatibility; delegates to update.sh.

DIR="$(cd "$(dirname "$0")" && pwd)"

exec "$DIR/update.sh" "$@"
