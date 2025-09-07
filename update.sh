#!/usr/bin/env bash
set -euo pipefail

# Unified updater/installer for metro_clock. Idempotent.
# Default: update code + Python deps. Optional: install apt deps and services.

usage() {
  cat <<EOF
Usage: $0 [options]
  --apt                 Install minimal apt dependencies (python, git, jq, curl)
  --kiosk               Install kiosk deps (Xorg, Chromium, fonts, unclutter)
  --install-services    Install and enable systemd services
  --env KEY=VALUE       Add KEY to /etc/default/metro-clock (repeatable)
  --write-config        Create a starter config.yaml (non-destructive if exists)
  --home LAT,LON        Coordinates for config (used with --write-config)
  --radius N            Radius meters for nearby selection (config)
  --config PATH         Config path (default: ./config.yaml)
  --pull                Pull latest git changes (skipped by default)
  -h, --help            Show this help

Examples:
  $0                  # update code and Python deps only
  sudo $0 --apt --kiosk --install-services \
       --env WMATA_API_KEY=xxxx --env HOST=127.0.0.1 --env PORT=8080
EOF
}

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO_DIR"

APT_MIN=0
APT_KIOSK=0
INSTALL_SERVICES=0
ENV_KV=()
WRITE_CONFIG=0
HOME_COORDS=""
RADIUS_M="1200"
CONFIG_PATH="config.yaml"
DO_PULL=0

ARGS_COUNT=$#
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apt) APT_MIN=1; shift ;;
    --kiosk) APT_KIOSK=1; shift ;;
    --install-services) INSTALL_SERVICES=1; shift ;;
    --env) ENV_KV+=("$2"); shift 2 ;;
    --write-config) WRITE_CONFIG=1; shift ;;
    --home) HOME_COORDS="$2"; shift 2 ;;
    --radius) RADIUS_M="$2"; shift 2 ;;
    --config) CONFIG_PATH="$2"; shift 2 ;;
    --pull) DO_PULL=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

as_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    sudo "$@"
  else
    "$@"
  fi
}

apt_install() {
  export DEBIAN_FRONTEND=noninteractive
  as_root apt-get update
  local pkgs=(python3 python3-venv python3-pip git ca-certificates jq curl)
  if [[ $APT_KIOSK -eq 1 ]]; then
    pkgs+=(xserver-xorg xinit chromium-browser unclutter fonts-noto-core fonts-noto-color-emoji)
  fi
  as_root apt-get install -y --no-install-recommends "${pkgs[@]}" || true
}

write_env_file() {
  local env_file="/etc/default/metro-clock"
  as_root install -d -m 0755 "$(dirname "$env_file")"
  if [[ ! -f "$env_file" ]]; then
    as_root tee "$env_file" >/dev/null <<EOF
# Environment for metro-clock services
PORT=8080
HOST=127.0.0.1
PYTHONPATH=${REPO_DIR}
EOF
  fi
  # Ensure the app user can read via group (for dev.sh). Group -> invoking user.
  as_root chgrp "${SUDO_USER:-${USER}}" "$env_file" || true
  as_root chmod 0640 "$env_file"
  for kv in "${ENV_KV[@]:-}"; do
    [[ -z "$kv" ]] && continue
    key="${kv%%=*}"; val="${kv#*=}"
    if grep -q "^${key}=" "$env_file"; then
      as_root sed -i "s|^${key}=.*|${key}=${val}|" "$env_file"
    else
      printf "%s\n" "${key}=${val}" | as_root tee -a "$env_file" >/dev/null
    fi
  done
  echo "$env_file updated"
}

install_services() {
  if [[ ! -f "${REPO_DIR}/backend/app.py" ]]; then
    echo "backend/app.py not found; skipping service install."
    return
  fi
  local env_file="/etc/default/metro-clock"
  local systemd_dir="/etc/systemd/system"
  local svc_api="metro-clock.service"
  local svc_kiosk="metro-kiosk.service"

  # FastAPI backend
  tee "${systemd_dir}/${svc_api}" >/dev/null <<EOF
[Unit]
Description=Metro Clock API (FastAPI)
After=network-online.target
Wants=network-online.target

[Service]
EnvironmentFile=${env_file}
WorkingDirectory=${REPO_DIR}
ExecStart=${REPO_DIR}/.venv/bin/uvicorn backend.app:app --host \\${HOST} --port \\${PORT}
Restart=always
RestartSec=2
User=${SUDO_USER:-${USER}}
Group=${SUDO_USER:-${USER}}

[Install]
WantedBy=multi-user.target
EOF

  # Chromium kiosk (detect binary)
  local chromium_bin="/usr/bin/chromium-browser"
  if [[ ! -x "$chromium_bin" ]] && command -v chromium >/dev/null 2>&1; then
    chromium_bin="$(command -v chromium)"
  fi
  tee "${systemd_dir}/${svc_kiosk}" >/dev/null <<EOF
[Unit]
Description=Chromium Kiosk for Metro Clock
After=graphical.target ${svc_api}
Wants=${svc_api}

[Service]
User=${SUDO_USER:-${USER}}
Environment=DISPLAY=:0
ExecStart=/usr/bin/startx ${chromium_bin} --kiosk --noerrdialogs --disable-translate --disable-features=TranslateUI --app=http://localhost:8080/
Restart=always
RestartSec=5

[Install]
WantedBy=graphical.target
EOF

  as_root systemctl daemon-reload
  as_root systemctl enable "${svc_api}" "${svc_kiosk}" || true
  echo "Installed services: ${svc_api}, ${svc_kiosk}"
}

write_config() {
  local path="$CONFIG_PATH"
  if [[ -f "$path" ]]; then
    echo "Config exists at $path; leaving as-is."
    return
  fi
  local lat="" lon=""
  if [[ -n "$HOME_COORDS" ]]; then
    lat="${HOME_COORDS%%,*}"
    lon="${HOME_COORDS#*,}"
  else
    if [[ -t 0 ]]; then
      read -r -p "Enter home latitude (e.g., 38.8895): " lat
      read -r -p "Enter home longitude (e.g., -77.0353): " lon
    else
      lat="38.8895"; lon="-77.0353"
    fi
  fi
  cat > "$path" <<EOF
home:
  lat: ${lat}
  lon: ${lon}
  radius_m: ${RADIUS_M}
rail:
  favorites: []
  lines: [RD, BL, OR, SV, YL, GR]
  refresh_s: 15
  max_stations: 5
bus:
  favorites: []
  extra_stops: []
  include_near_stations: []
  include_near_radius_m: 250
  include_near_max_stops: 3
  routes: []
  refresh_s: 20
  max_stops: 3
  max_arrivals: 8
bike_share:
  enabled: true
  radius_m: 800
  favorites: []
  refresh_s: 45
weather:
  provider: open-meteo
  refresh_s: 600
ui:
  layout: combined
  rotate_ms: 0
EOF
  echo "Wrote starter config to $path"
}

if [[ $DO_PULL -eq 1 ]]; then
  echo "Fetching latest code..."
  if [[ -d .git ]]; then
    if git remote -v >/dev/null 2>&1; then
      git fetch --all --prune || echo "Warning: git fetch failed; continuing"
    fi
    if git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
      git pull --ff-only || echo "Note: fast-forward pull failed or diverged; leaving code as-is."
    else
      echo "Note: no upstream tracking branch configured; skipping pull."
    fi
  else
    echo "Warning: not a git repo; skipping pull"
  fi
fi

if [[ $APT_MIN -eq 1 || $APT_KIOSK -eq 1 ]]; then
  echo "Installing apt dependencies..."
  apt_install
fi

if [[ ! -d .venv ]]; then
  echo "Creating Python venv..."
  python3 -m venv .venv
fi
# ---------------------------
# Interactive wizard (default)
# ---------------------------
if [[ $ARGS_COUNT -eq 0 ]]; then
  echo "\nInteractive setup/update"
  echo "========================"
  echo "This will pull code, ensure Python deps, and optionally set system settings."

  # Offer apt minimal deps
  read -r -p "Install/refresh minimal apt deps (python/git/jq/curl)? [Y/n] " yn
  case "${yn:-Y}" in [Yy]*) APT_MIN=1 ;; esac

  # Offer kiosk deps
  read -r -p "Install/refresh kiosk deps (Xorg/Chromium/fonts/unclutter)? [y/N] " yn
  case "${yn:-N}" in [Yy]*) APT_KIOSK=1 ;; esac

  # WMATA key manage
  ENV_FILE="/etc/default/metro-clock"
  EXISTING_KEY=""
  if [[ -f "$ENV_FILE" ]]; then
    EXISTING_KEY=$(grep -E '^WMATA_API_KEY=' "$ENV_FILE" | sed 's/^WMATA_API_KEY=//') || true
  fi
  if [[ -n "$EXISTING_KEY" ]]; then
    MASKED="****${EXISTING_KEY: -4}"
    read -r -p "Reuse existing WMATA_API_KEY ($MASKED)? [Y/n] " yn
    case "${yn:-Y}" in
      [Nn]*) read -r -p "Enter new WMATA_API_KEY (leave blank to clear): " NEWKEY; ENV_KV+=("WMATA_API_KEY=${NEWKEY}") ;;
      *) : ;;
    esac
  else
    read -r -p "Enter WMATA_API_KEY (leave blank to skip for now): " NEWKEY
    if [[ -n "$NEWKEY" ]]; then ENV_KV+=("WMATA_API_KEY=${NEWKEY}"); fi
  fi
  if [[ ${#ENV_KV[@]} -gt 0 ]]; then
    write_env_file
  fi

  # Config manage
  if [[ -f "$CONFIG_PATH" ]]; then
    echo "Found config at $CONFIG_PATH."
    read -r -p "Reuse existing config.yaml? [Y/n] " yn
    case "${yn:-Y}" in
      [Nn]*) WRITE_CONFIG=1 ;;
      *) WRITE_CONFIG=0 ;;
    esac
  else
    WRITE_CONFIG=1
  fi
  if [[ $WRITE_CONFIG -eq 1 ]]; then
    read -r -p "Enter home address (or leave blank to enter lat/lon): " addr
    lat=""; lon=""
    if [[ -n "$addr" ]]; then
      if command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
        echo "Geocoding via OpenStreetMap Nominatim..."
        set +e
        GEO_JSON=$(curl -sS -A "metro-clock-setup/1.0" --get \
          --data-urlencode "q=${addr}" \
          --data-urlencode "format=json" \
          --data-urlencode "limit=1" \
          https://nominatim.openstreetmap.org/search)
        RC=$?
        set -e
        if [[ $RC -eq 0 && -n "$GEO_JSON" ]]; then
          lat=$(echo "$GEO_JSON" | jq -r '.[0].lat // empty')
          lon=$(echo "$GEO_JSON" | jq -r '.[0].lon // empty')
          [[ -n "$lat" && -n "$lon" ]] && echo "Resolved: lat=$lat lon=$lon"
        fi
      else
        echo "curl/jq not available for geocoding; installing minimal apt deps..."
        APT_MIN=1
        apt_install || true
        if command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
          echo "Geocoding via OpenStreetMap Nominatim..."
          set +e
          GEO_JSON=$(curl -sS -A "metro-clock-setup/1.0" --get \
            --data-urlencode "q=${addr}" \
            --data-urlencode "format=json" \
            --data-urlencode "limit=1" \
            https://nominatim.openstreetmap.org/search)
          RC=$?
          set -e
          if [[ $RC -eq 0 && -n "$GEO_JSON" ]]; then
            lat=$(echo "$GEO_JSON" | jq -r '.[0].lat // empty')
            lon=$(echo "$GEO_JSON" | jq -r '.[0].lon // empty')
            [[ -n "$lat" && -n "$lon" ]] && echo "Resolved: lat=$lat lon=$lon"
          fi
        else
          echo "Still no curl/jq; falling back to manual lat/lon entry."
        fi
      fi
    fi
    if [[ -z "$lat" || -z "$lon" ]]; then
      read -r -p "Enter home latitude (e.g., 38.8895): " lat
      read -r -p "Enter home longitude (e.g., -77.0353): " lon
    fi
    read -r -p "Enter search radius meters (e.g., 1200): " rm
    HOME_COORDS="${lat},${lon}"; [[ -n "$rm" ]] && RADIUS_M="$rm"
    write_config
    # Optional favorites (auto-nearby is default if left empty)
    read -r -p "Do you want to pick favorites now? [y/N] " pf
    case "${pf:-N}" in
      [Yy]*)
        read -r -p "Enter rail station codes comma-separated (or leave blank): " rf
        read -r -p "Enter bus stop IDs comma-separated (or leave blank): " bf
        read -r -p "Enter bikeshare station_ids comma-separated (or leave blank): " kf
        if [[ -n "$rf$bf$kf" ]]; then
          # Inline edit favorites within section ranges
          if [[ -n "$rf" ]]; then
            sed -i "/^rail:$/, /^bus:/{s/^  favorites: .*/  favorites: [${rf// /}/]/}" "$CONFIG_PATH"
          fi
          if [[ -n "$bf" ]]; then
            sed -i "/^bus:$/, /^bike_share:/{s/^  favorites: .*/  favorites: [${bf// /}/]/}" "$CONFIG_PATH"
          fi
          if [[ -n "$kf" ]]; then
            sed -i "/^bike_share:$/, /^weather:/{s/^  favorites: .*/  favorites: [${kf// /}/]/}" "$CONFIG_PATH"
          fi
        fi
        ;;
      *) echo "Skipping favorites; will auto-select nearby based on your address." ;;
    esac
    echo "Config saved to $CONFIG_PATH"
  fi

  # Offer to pull latest from git
  if [[ -d .git ]]; then
    read -r -p "Pull latest changes from git? [y/N] " yn
    case "${yn:-N}" in [Yy]*) DO_PULL=1 ;; esac
  fi

  # Offer to install and enable systemd services
  read -r -p "Install and enable systemd services (backend + kiosk)? [y/N] " yn
  case "${yn:-N}" in [Yy]*) INSTALL_SERVICES=1 ;; esac
fi

# After interactive (or flags), perform actions
if [[ $DO_PULL -eq 1 ]]; then
  if [[ -d .git ]]; then
    if git remote -v >/dev/null 2>&1; then
      git fetch --all --prune || echo "Warning: git fetch failed; continuing"
    fi
    if git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
      git pull --ff-only || echo "Note: fast-forward pull failed or diverged; leaving code as-is."
    else
      echo "Note: no upstream tracking branch configured; skipping pull."
    fi
  else
    echo "Warning: not a git repo; skipping pull"
  fi
fi

if [[ $APT_MIN -eq 1 || $APT_KIOSK -eq 1 ]]; then
  echo "Installing apt dependencies..."
  apt_install
fi

if [[ ! -d .venv ]]; then
  echo "Creating Python venv..."
  python3 -m venv .venv
fi
# shellcheck disable=SC1091
source .venv/bin/activate

echo "Upgrading pip and deps..."
pip install --upgrade pip
if [[ -f requirements.txt ]]; then
  pip install -r requirements.txt
else
  pip install fastapi uvicorn httpx PyYAML Jinja2
fi

if [[ ${#ENV_KV[@]} -gt 0 ]]; then
  write_env_file
fi

if [[ $WRITE_CONFIG -eq 1 ]]; then
  write_config
fi

if [[ $INSTALL_SERVICES -eq 1 ]]; then
  install_services
fi

echo "Restarting services if present..."
if command -v systemctl >/dev/null 2>&1; then
  systemctl list-units --type=service --all | grep -q '^metro-clock.service' && as_root systemctl restart metro-clock.service || true
  systemctl list-units --type=service --all | grep -q '^metro-kiosk.service' && as_root systemctl restart metro-kiosk.service || true
fi

echo "Done."
if command -v systemctl >/dev/null 2>&1; then
  if systemctl is-active --quiet metro-clock.service; then
    echo "- Backend service is active. Try: curl -sS http://127.0.0.1:8080/ | head -n1"
  else
    echo "- Backend service not active. Start with: sudo systemctl start metro-clock.service"
  fi
  if systemctl is-enabled --quiet metro-kiosk.service; then
    echo "- Kiosk service is installed. Start with: sudo systemctl start metro-kiosk.service"
  fi
fi
