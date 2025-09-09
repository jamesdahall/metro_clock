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
  --browser NAME        Browser: auto|chromium|epiphany|surf|netsurf (default: auto)
  --kiosk-session TYPE  xinitrc (default) or wrapper
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
# Preferred browser for kiosk (auto, chromium, epiphany, surf, netsurf)
BROWSER_PREF="auto"
# Kiosk session type: xinitrc (resilient default) or wrapper
KIOSK_SESSION="xinitrc"

# Detect architecture early
ARCH="$(uname -m 2>/dev/null || echo unknown)"

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
    --browser) BROWSER_PREF="$2"; shift 2 ;;
    --kiosk-session) KIOSK_SESSION="$2"; shift 2 ;;
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
  local pkgs=(python3 python3-venv python3-pip git ca-certificates jq curl unattended-upgrades)
  if [[ $APT_KIOSK -eq 1 ]]; then
    pkgs+=(xserver-xorg xinit xserver-xorg-legacy x11-xserver-utils unclutter fonts-noto-core fonts-noto-color-emoji)
    # Choose browser packages based on requested preference or architecture
    case "${BROWSER_PREF}:${ARCH}" in
      chromium:*)         pkgs+=(chromium-browser) ;;
      epiphany:*)         pkgs+=(epiphany-browser) ;;
      auto:armv6l)        pkgs+=(surf) ;;
      surf:*)             pkgs+=(surf) ;;
      netsurf:*)          pkgs+=(netsurf-gtk) ;;
      auto:*)             pkgs+=(chromium-browser) ;;
    esac
  fi
  as_root apt-get install -y --no-install-recommends "${pkgs[@]}" || true
  # Ensure unattended upgrades are enabled for security updates
  as_root tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
}

# Configure Xorg to allow non-root user to start X on TTY1
configure_xorg_legacy() {
  if [[ $APT_KIOSK -eq 1 ]]; then
    # Ensure package is present (best-effort)
    as_root apt-get install -y --no-install-recommends xserver-xorg-legacy >/dev/null 2>&1 || true
    local xw=/etc/Xwrapper.config
    if [[ -f "$xw" ]]; then
      if grep -q '^allowed_users=' "$xw"; then
        as_root sed -i 's/^allowed_users=.*/allowed_users=anybody/' "$xw"
      else
        printf "allowed_users=anybody\n" | as_root tee -a "$xw" >/dev/null
      fi
    else
      printf "allowed_users=anybody\nneeds_root_rights=yes\n" | as_root tee "$xw" >/dev/null
    fi
  fi
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

  # FastAPI backend (preserve \${HOST}/\${PORT} for systemd env)
  local LHOST='${HOST}'
  local LPORT='${PORT}'
  as_root tee "${systemd_dir}/${svc_api}" >/dev/null <<EOF
[Unit]
Description=Metro Clock API (FastAPI)
After=network-online.target
Wants=network-online.target

[Service]
EnvironmentFile=${env_file}
WorkingDirectory=${REPO_DIR}
ExecStart=${REPO_DIR}/.venv/bin/uvicorn backend.app:app --host ${LHOST} --port ${LPORT}
Restart=always
RestartSec=2
User=${SUDO_USER:-${USER}}
Group=${SUDO_USER:-${USER}}

[Install]
WantedBy=multi-user.target
EOF

  # Determine kiosk browser and command
  local browser_cmd=""
  pick_browser() {
    case "$BROWSER_PREF" in
      chromium)
        if command -v chromium-browser >/dev/null 2>&1; then echo "chromium-browser"; return; fi
        if command -v chromium >/dev/null 2>&1; then echo "chromium"; return; fi
        ;;
      epiphany)
        if command -v epiphany-browser >/dev/null 2>&1; then echo "epiphany-browser"; return; fi
        ;;
      surf)
        if command -v surf >/dev/null 2>&1; then echo "surf"; return; fi
        ;;
      netsurf)
        if command -v netsurf-gtk >/dev/null 2>&1; then echo "netsurf-gtk"; return; fi
        ;;
    esac
    # Auto mode fallback: ARMv6 -> surf, else chromium
    if [[ "$ARCH" == "armv6l" ]]; then
      if command -v surf >/dev/null 2>&1; then echo "surf"; return; fi
      if command -v epiphany-browser >/dev/null 2>&1; then echo "epiphany-browser"; return; fi
    fi
    if command -v chromium-browser >/dev/null 2>&1; then echo "chromium-browser"; return; fi
    if command -v chromium >/dev/null 2>&1; then echo "chromium"; return; fi
    if command -v epiphany-browser >/dev/null 2>&1; then echo "epiphany-browser"; return; fi
    if command -v surf >/dev/null 2>&1; then echo "surf"; return; fi
    if command -v netsurf-gtk >/dev/null 2>&1; then echo "netsurf-gtk"; return; fi
    echo ""; return
  }
  browser_cmd="$(pick_browser)"

  # Prepare kiosk session
  local user_home="/home/${SUDO_USER:-${USER}}"
  if [[ "$KIOSK_SESSION" == "xinitrc" ]]; then
    as_root bash -lc "cat > '${user_home}/.xinitrc' <<'EOL'
#!/bin/sh
exec >/tmp/kiosk-x.log 2>&1
set -x
export DISPLAY=:0
if command -v xset >/dev/null 2>&1; then xset s off -dpms || true; fi
if command -v xsetroot >/dev/null 2>&1; then xsetroot -solid black || true; fi
if command -v xrandr >/dev/null 2>&1; then xrandr --output HDMI-1 --mode 1280x720 --rate 60 || true; fi
command -v matchbox-window-manager >/dev/null 2>&1 && matchbox-window-manager -use_titlebar no -use_cursor no &
command -v unclutter >/dev/null 2>&1 && unclutter -idle 0 &
sleep 1
URL="http://localhost:8080/"
BIN='${browser_cmd}'
while true; do
  case "$BIN" in
    chromium-browser|chromium)
      "$BIN" --kiosk --noerrdialogs --disable-translate --disable-features=TranslateUI --app="$URL" || true ;;
    epiphany-browser)
      "$BIN" --application-mode "$URL" || true ;;
    surf)
      "$BIN" -Fk "$URL" || true ;;
    netsurf-gtk)
      "$BIN" "$URL" || true ;;
    *) echo "No supported browser found: $BIN" >&2; sleep 5 ;;
  esac
  sleep 2
done
EOL"
    as_root chown "${SUDO_USER:-${USER}}":"${SUDO_USER:-${USER}}" "${user_home}/.xinitrc"
    as_root chmod +x "${user_home}/.xinitrc"
  else
    # Wrapper mode
    local bin_kiosk="/usr/local/bin/metro-kiosk.sh"
    as_root bash -lc "cat > '$bin_kiosk' <<EOP
#!/usr/bin/env bash
set -euo pipefail
export DISPLAY=:0
unclutter -idle 0 &
matchbox-window-manager -use_titlebar no -use_cursor no &
exec ${browser_cmd} -Fk http://localhost:8080/
EOP"
    as_root chmod +x "$bin_kiosk"
  fi

  # Lean kiosk service using xinit on TTY1
  as_root tee "${systemd_dir}/${svc_kiosk}" >/dev/null <<EOF
[Unit]
Description=Chromium Kiosk for Metro Clock (xinit)
After=multi-user.target ${svc_api}
Wants=${svc_api}

[Service]
User=${SUDO_USER:-${USER}}
TTYPath=/dev/tty1
StandardInput=tty
TTYReset=yes
TTYVHangup=yes
ExecStart=/usr/bin/xinit ${user_home}/.xinitrc -- :0 vt1 -keeptty
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  # Avoid getty contention on TTY1 (best-effort)
  as_root systemctl disable --now getty@tty1.service || true

  # Display power scripts and timers
  local bin_off="/usr/local/bin/metro-display-off.sh"
  local bin_on="/usr/local/bin/metro-display-on.sh"
  as_root tee "$bin_off" >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
systemctl stop metro-kiosk.service || true
if command -v vcgencmd >/dev/null 2>&1; then
  vcgencmd display_power 0 || true
fi
EOF
  as_root chmod +x "$bin_off"

  as_root tee "$bin_on" >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if command -v vcgencmd >/dev/null 2>&1; then
  vcgencmd display_power 1 || true
fi
systemctl start metro-kiosk.service || true
EOF
  as_root chmod +x "$bin_on"

  as_root tee "${systemd_dir}/metro-display-off.service" >/dev/null <<EOF
[Unit]
Description=Turn display off for Metro Clock

[Service]
Type=oneshot
ExecStart=${bin_off}
EOF

  as_root tee "${systemd_dir}/metro-display-on.service" >/dev/null <<EOF
[Unit]
Description=Turn display on for Metro Clock

[Service]
Type=oneshot
ExecStart=${bin_on}
EOF

  as_root tee "${systemd_dir}/metro-display-off.timer" >/dev/null <<'EOF'
[Unit]
Description=Nightly display off for Metro Clock

[Timer]
OnCalendar=22:30
Persistent=true

[Install]
WantedBy=timers.target
EOF

  as_root tee "${systemd_dir}/metro-display-on.timer" >/dev/null <<'EOF'
[Unit]
Description=Morning display on for Metro Clock

[Timer]
OnCalendar=05:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

  # Weekly reboot during off window (Sunday 03:30)
  local bin_reboot="/usr/local/bin/metro-weekly-reboot.sh"
  as_root tee "$bin_reboot" >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
systemctl stop metro-kiosk.service || true
sleep 2
systemctl reboot
EOF
  as_root chmod +x "$bin_reboot"

  as_root tee "${systemd_dir}/metro-weekly-reboot.service" >/dev/null <<EOF
[Unit]
Description=Weekly maintenance reboot for Metro Clock

[Service]
Type=oneshot
ExecStart=${bin_reboot}
EOF

  as_root tee "${systemd_dir}/metro-weekly-reboot.timer" >/dev/null <<'EOF'
[Unit]
Description=Weekly reboot timer for Metro Clock (Sun 03:30)

[Timer]
OnCalendar=Sun 03:30
Persistent=true

[Install]
WantedBy=timers.target
EOF

  as_root systemctl daemon-reload
  as_root systemctl enable "${svc_api}" "${svc_kiosk}" || true
  as_root systemctl enable --now metro-display-off.timer metro-display-on.timer metro-weekly-reboot.timer || true
  echo "Installed services: ${svc_api}, ${svc_kiosk}, display timers (22:30 off, 05:00 on), weekly reboot (Sun 03:30)"
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
  configure_xorg_legacy || true
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
