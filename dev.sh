#!/usr/bin/env bash
set -euo pipefail

# Dev server for local testing (uses real APIs; no mock mode).
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

if [[ ! -d .venv ]]; then
  python3 -m venv .venv
fi
# shellcheck disable=SC1091
source .venv/bin/activate

pip install --upgrade pip
if [[ -f requirements.txt ]]; then
  pip install -r requirements.txt
else
  pip install fastapi uvicorn pyyaml httpx jinja2
fi

# Load system env if present (WMATA_API_KEY, HOST, PORT)
if [[ -f /etc/default/metro-clock ]]; then
  if [[ -r /etc/default/metro-clock ]]; then
    # shellcheck disable=SC1091
    set -a; . /etc/default/metro-clock || true; set +a
  else
    # Fallback: read key via sudo without exposing full file
    if [[ -z "${WMATA_API_KEY:-}" ]]; then
      WMATA_API_KEY=$(sudo awk -F= '/^WMATA_API_KEY=/{print $2; exit}' /etc/default/metro-clock 2>/dev/null || true)
      export WMATA_API_KEY
    fi
  fi
fi

export PORT="${PORT:-8080}"
export HOST="${HOST:-127.0.0.1}"

# Startup diagnostics
if [[ -n "${WMATA_API_KEY:-}" ]]; then
  echo "WMATA_API_KEY detected (last4: ${WMATA_API_KEY: -4})"
else
  echo "WMATA_API_KEY not set; WMATA calls will fail (no mock)."
fi

if [[ ! -f backend/app.py ]]; then
  echo "backend/app.py not found. Please scaffold backend or let me create it." >&2
  exit 1
fi

exec uvicorn backend.app:app --reload --host "$HOST" --port "$PORT"
