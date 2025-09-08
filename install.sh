#!/usr/bin/env bash
set -euo pipefail

# Bootstrap installer for metro_clock.
# Fetchable via: curl -fsSL <raw-url>/install.sh | sudo bash -s -- [flags]
#
# Flags (all optional; can also be set via environment):
#   --wmata-key KEY          WMATA API key (or WMATA_API_KEY env)
#   --address "ADDR"         Address to geocode to LAT,LON (uses Nominatim)
#   --home LAT,LON           Home coordinates override (comma-separated)
#   --radius N               Radius meters for nearby selection (default 1200)
#   --repo URL               Git repo to clone (default GitHub)
#   --branch BRANCH          Git branch to checkout (default repo default)
#   --dir PATH               Install dir (default /home/<user>/metro_clock)
#   --kiosk                  Install kiosk deps (Xorg/Chromium/fonts/unclutter)
#   --services               Install and enable systemd services
#   --kiosk-services         Shorthand: enable both --kiosk and --services
#   --full                   Shorthand: --apt (default) + --kiosk + --services + --yes
#   --wizard                 Ask all questions up front (address/home, API key, radius, kiosk/services) with validation
#   --bg, --background       Run the install phase in background after confirmation
#   --no-apt                 Skip apt installs (assume deps present)
#   --pull                   Pull latest after clone
#   -y, --yes, --assume-yes  Non-interactive apt (-y)
#
# Examples:
#   curl -fsSL RAW_URL/install.sh | sudo bash -s -- \
#     --wmata-key YOUR_KEY --address "123 Main St, Arlington, VA" \
#     --radius 1200 --kiosk --services

WMATA_API_KEY_DEFAULT="${WMATA_API_KEY:-}"
ADDRESS=""
HOME_COORDS=""
RADIUS_M="1200"
REPO_URL="https://github.com/jamesdahall/metro_clock.git"
BRANCH=""
TARGET_DIR=""
INSTALL_KIOSK=0
INSTALL_SERVICES=0
DO_PULL=0
DO_APT=1
APT_YES_FLAG=""
WIZARD=0
RUN_BACKGROUND=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --wmata-key) WMATA_API_KEY_DEFAULT="$2"; shift 2 ;;
    --address) ADDRESS="$2"; shift 2 ;;
    --home) HOME_COORDS="$2"; shift 2 ;;
    --radius) RADIUS_M="$2"; shift 2 ;;
    --repo) REPO_URL="$2"; shift 2 ;;
    --branch) BRANCH="$2"; shift 2 ;;
    --dir) TARGET_DIR="$2"; shift 2 ;;
    --kiosk) INSTALL_KIOSK=1; shift ;;
    --services) INSTALL_SERVICES=1; shift ;;
    --kiosk-services) INSTALL_KIOSK=1; INSTALL_SERVICES=1; shift ;;
    --full) INSTALL_KIOSK=1; INSTALL_SERVICES=1; DO_APT=1; APT_YES_FLAG="-y"; shift ;;
    --wizard) WIZARD=1; shift ;;
    --bg|--background) RUN_BACKGROUND=1; shift ;;
    --pull) DO_PULL=1; shift ;;
    --no-apt) DO_APT=0; shift ;;
    -y|--yes|--assume-yes) APT_YES_FLAG="-y"; shift ;;
    -h|--help)
      sed -n '1,120p' "$0" | sed 's/^# \{0,1\}//' | sed -n '1,80p'
      exit 0
      ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# Determine target user and install directory
REAL_USER="${SUDO_USER:-${USER}}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6 || echo "/home/$REAL_USER")"
TARGET_DIR="${TARGET_DIR:-${REAL_HOME}/metro_clock}"

echo "==> Using user: $REAL_USER"
echo "==> Install dir: $TARGET_DIR"

apt_install_min() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install ${APT_YES_FLAG} -y --no-install-recommends \
    git ca-certificates curl jq python3 python3-venv python3-pip || true
}

apt_install_kiosk() {
  export DEBIAN_FRONTEND=noninteractive
  # Chromium package name varies; try both later when starting kiosk
  apt-get install ${APT_YES_FLAG} -y --no-install-recommends \
    xserver-xorg xinit unclutter fonts-noto-core fonts-noto-color-emoji \
    chromium-browser || apt-get install ${APT_YES_FLAG} -y chromium || true
  # Optional: vcgencmd for display power scripts
  apt-get install ${APT_YES_FLAG} -y --no-install-recommends libraspberrypi-bin || true
}

ensure_prompt_tools() {
  # Ensure tools needed for validation prompts exist (curl + jq)
  if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    echo "==> Installing prompt dependencies (curl, jq)..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends curl jq ca-certificates >/dev/null 2>&1 || true
  fi
}

maybe_geocode() {
  local addr="$1"
  local lat="" lon=""
  if [[ -z "$addr" ]]; then
    echo ""
    return 0
  fi
  echo "==> Geocoding address..."
  local geo
  set +e
  geo=$(curl -sS -A "metro-clock-install/1.0" --get \
    --data-urlencode "q=${addr}" \
    --data-urlencode "format=json" \
    --data-urlencode "limit=1" \
    https://nominatim.openstreetmap.org/search)
  local rc=$?
  set -e
  if [[ $rc -eq 0 && -n "$geo" ]]; then
    lat=$(echo "$geo" | jq -r '.[0].lat // empty')
    lon=$(echo "$geo" | jq -r '.[0].lon // empty')
  fi
  if [[ -n "$lat" && -n "$lon" ]]; then
    echo "==> Resolved to lat=$lat lon=$lon"
    echo "${lat},${lon}"
  else
    echo "==> Geocoding failed; falling back to defaults" >&2
    echo ""
  fi
}

validate_wmata_key() {
  local key="$1"
  if [[ -z "$key" ]]; then
    echo ""; return 0
  fi
  local code
  code=$(curl -m 10 -s -o /dev/null -w "%{http_code}" \
    -H "api_key: ${key}" \
    "https://api.wmata.com/Rail.svc/json/jStations" || echo "000")
  if [[ "$code" == "200" ]]; then
    echo "$key"; return 0
  fi
  echo ""; return 1
}

# Optional questionnaire: ask everything up front with validation
if [[ $WIZARD -eq 1 ]]; then
  ensure_prompt_tools
  echo "==> Interactive setup (wizard)"
  # Home coordinates
  while :; do
    read -r -p "Enter address to geocode OR 'lat,lon' (default ${HOME_COORDS:-38.8895,-77.0353}): " entry || entry=""
    entry="${entry:-${HOME_COORDS:-38.8895,-77.0353}}"
    if [[ "$entry" =~ ^-?[0-9]+\.?[0-9]*,-?[0-9]+\.?[0-9]*$ ]]; then
      HOME_COORDS="$entry"; break
    else
      tmp="$(maybe_geocode "$entry")"
      if [[ -n "$tmp" ]]; then HOME_COORDS="$tmp"; break; fi
      echo "Could not resolve address; try again or enter 'lat,lon' directly."
    fi
  done
  # Radius
  while :; do
    read -r -p "Search radius meters [${RADIUS_M}]: " rm || rm=""
    rm="${rm:-$RADIUS_M}"
    if [[ "$rm" =~ ^[0-9]{2,6}$ ]]; then RADIUS_M="$rm"; break; fi
    echo "Please enter a number (e.g., 1200)."
  done
  # API key
  while :; do
    read -r -p "Enter WMATA_API_KEY (leave blank to skip): " WMATA_API_KEY_DEFAULT || WMATA_API_KEY_DEFAULT=""
    if [[ -z "$WMATA_API_KEY_DEFAULT" ]]; then
      echo "Proceeding without a key; rail/bus will be unavailable until added."; break
    fi
    if validate_wmata_key "$WMATA_API_KEY_DEFAULT" >/dev/null; then
      echo "WMATA key looks valid (last4: ${WMATA_API_KEY_DEFAULT: -4})."; break
    else
      echo "Key appears invalid or network unreachable; try again or leave blank to skip."
    fi
  done
  # Kiosk/Services
  read -r -p "Install kiosk dependencies (Chromium/Xorg/fonts/unclutter)? [y/N] " yn || yn=""
  case "${yn:-N}" in [Yy]*) INSTALL_KIOSK=1;; *) INSTALL_KIOSK=0;; esac
  read -r -p "Install and enable systemd services (backend + kiosk)? [y/N] " yn || yn=""
  case "${yn:-N}" in [Yy]*) INSTALL_SERVICES=1;; *) INSTALL_SERVICES=0;; esac

  # Summary
  echo "\nSummary"
  echo "-------"
  echo "Home:         $HOME_COORDS"
  echo "Radius:       $RADIUS_M m"
  echo "WMATA key:    ${WMATA_API_KEY_DEFAULT:+****${WMATA_API_KEY_DEFAULT: -4}}${WMATA_API_KEY_DEFAULT:-<none>}"
  echo "Kiosk deps:   $([[ $INSTALL_KIOSK -eq 1 ]] && echo yes || echo no)"
  echo "Services:     $([[ $INSTALL_SERVICES -eq 1 ]] && echo yes || echo no)"
  read -r -p "Proceed with installation? [Y/n] " yn || yn="Y"
  case "${yn:-Y}" in [Yy]*) : ;; *) echo "Cancelled."; exit 0 ;; esac
fi

if [[ $DO_APT -eq 1 ]]; then
  echo "==> Installing minimal apt dependencies..."
  apt_install_min
fi

# Prepare home and clone repo
install -d -m 0755 -o "$REAL_USER" -g "$REAL_USER" "$REAL_HOME"
cd "$REAL_HOME"
if [[ ! -d "$TARGET_DIR/.git" ]]; then
  echo "==> Cloning repo: $REPO_URL"
  sudo -u "$REAL_USER" git clone "$REPO_URL" "$TARGET_DIR"
fi
cd "$TARGET_DIR"

if [[ -n "$BRANCH" ]]; then
  echo "==> Checking out branch: $BRANCH"
  sudo -u "$REAL_USER" git fetch --all --prune || true
  sudo -u "$REAL_USER" git checkout "$BRANCH" || true
fi

if [[ $DO_PULL -eq 1 ]]; then
  echo "==> Pulling latest changes"
  sudo -u "$REAL_USER" git pull --ff-only || true
fi

# Compute HOME_COORDS
if [[ -z "$HOME_COORDS" && -n "$ADDRESS" ]]; then
  HOME_COORDS="$(maybe_geocode "$ADDRESS")"
fi

# Interactive fallback if geocoding failed or neither provided
if [[ -z "$HOME_COORDS" ]]; then
  if [[ -t 0 ]]; then
    echo "==> Home coordinates not set. Let's configure them."
    while :; do
      read -r -p "Enter address to geocode OR 'lat,lon' (default 38.8895,-77.0353): " entry || entry=""
      entry="${entry:-38.8895,-77.0353}"
      if [[ "$entry" =~ ^-?[0-9]+\.?[0-9]*,-?[0-9]+\.?[0-9]*$ ]]; then
        HOME_COORDS="$entry"
        break
      else
        tmp="$(maybe_geocode "$entry")"
        if [[ -n "$tmp" ]]; then
          HOME_COORDS="$tmp"; break
        else
          echo "Could not resolve address. Try entering 'lat,lon' directly (e.g., 38.8895,-77.0353)."
        fi
      fi
    done
  else
    HOME_COORDS="38.8895,-77.0353"
  fi
fi

if [[ -t 0 ]]; then
  # Prompt for key if empty or invalid
  while :; do
    if validate_wmata_key "$WMATA_API_KEY_DEFAULT" >/dev/null; then
      break
    fi
    if [[ -n "$WMATA_API_KEY_DEFAULT" ]]; then
      echo "==> The provided WMATA API key appears invalid or unreachable."
    fi
    read -r -p "Enter WMATA_API_KEY (leave blank to proceed without): " WMATA_API_KEY_DEFAULT || WMATA_API_KEY_DEFAULT=""
    if [[ -z "$WMATA_API_KEY_DEFAULT" ]]; then
      echo "==> Proceeding without a WMATA key. Rail/Bus data will not load."
      break
    fi
    if validate_wmata_key "$WMATA_API_KEY_DEFAULT" >/dev/null; then
      echo "==> WMATA key looks valid (last4: ${WMATA_API_KEY_DEFAULT: -4})."
      break
    else
      echo "==> Still invalid; please try again or leave blank to skip."
    fi
  done
fi

# Build update.sh flags
FLAGS=("--apt")
if [[ $INSTALL_KIOSK -eq 1 ]]; then FLAGS+=("--kiosk"); fi
if [[ $INSTALL_SERVICES -eq 1 ]]; then FLAGS+=("--install-services"); fi
if [[ -n "$WMATA_API_KEY_DEFAULT" ]]; then FLAGS+=("--env" "WMATA_API_KEY=${WMATA_API_KEY_DEFAULT}"); fi
FLAGS+=("--write-config" "--home" "$HOME_COORDS" "--radius" "$RADIUS_M")

echo "==> Running updater: ./update.sh ${FLAGS[*]}"
if [[ $RUN_BACKGROUND -eq 1 ]]; then
  LOG=/var/log/metro-install.log
  echo "==> Running in background. Logs: $LOG"
  nohup ./update.sh "${FLAGS[@]}" > "$LOG" 2>&1 & disown
  echo "PID: $!"
  echo "Tail logs: sudo tail -f $LOG"
else
  exec ./update.sh "${FLAGS[@]}"
fi
