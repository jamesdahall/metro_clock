DC Metro (WMATA) + Bikeshare + Weather Display
==============================================

A lightweight, kiosk-style dashboard showing WMATA rail and bus arrivals, Capital Bikeshare dock availability, current weather, and service impacts — optimized for a 1920×1080 display. Designed to run 24/7 on a Raspberry Pi Zero W (development on a Raspberry Pi 4).

---

Goals
-----

- High-contrast, at-a-glance arrivals for rail and bus simultaneously.
- Runs 24/7 on Pi Zero W in kiosk fullscreen.
- Minimal network/API usage with resilient caching.
- Simple YAML config; no cloud dependency beyond WMATA API.
- Local development on Pi 4; deploy to Pi Zero W.
- Single-location setup: configure home coordinates once during initial install.

---

Features
--------

- Combined rail + bus view: Show both at the same time, no tabbing.
- Nearby stations/stops: Select nearest rail stations and bus stops from configured home location.
- Rail predictions: Line, destination, minutes, platform, car count; color-coded by line.
- Bus predictions: Route, destination, minutes; grouping by stop.
- Service impacts: Prominent panel for WMATA incidents/disruptions (rail and bus), severity-tagged.
- Bikeshare counts: Capital Bikeshare dock status (bikes and docks available) via GBFS feeds.
- Bikeshare counts: Capital Bikeshare dock status via GBFS (bikes, docks, and e-bikes when available).
- Clock and weather: Always-visible clock; current conditions + short summary via Open‑Meteo.
- Favorites & filters: Pin specific stations/stops/routes/lines; radius-based auto-selection optional.
- Rotating views (optional): Cycle expanded panels; default remains simultaneous combined view.
- Offline/poor network mode: Use last-known predictions with staleness badges and age indicator.
- Performance-aware UI: Large fonts, dark theme, low reflow; 1080p-optimized.
- Auto start: Boots into Chromium kiosk; watchdog restarts on crash.

---

Architecture
------------

- Backend: Python (FastAPI or Flask) service on the Pi
  - Fetches WMATA data on a short interval (e.g., every 10–20s), caches in memory.
  - Exposes a tiny REST or Server-Sent Events (SSE) endpoint to the frontend.
  - Handles rate-limits, retries, and backoff; consolidates/massages data.
  - Optional SQLite for static reference data (station/stop metadata) and durable cache.
- Integrations: Lightweight HTTP clients using `httpx`
  - WMATA Rail and Bus predictions.
  - Capital Bikeshare GBFS (station information/status) for live bike/dock counts.
  - Open‑Meteo weather API for current conditions (no API key required).
- Frontend: Minimal static page with vanilla JS
  - Polls backend JSON or subscribes to SSE for live updates.
  - Renders a compact grid for rail and bus side-by-side; bikeshare and weather panels.
  - No heavy frameworks; zero build step by default.
- Config: YAML file (e.g., `config.yaml`)
  - Home coordinates, radius, favorite stations/stops, filters, refresh intervals, layout/rotation (dark theme baked-in).
  - WMATA API key via environment variable.
  - Optional: enable/disable bikeshare and weather; set nearest-bike radius.
- System services
  - `systemd` unit for backend API service.
  - `systemd` unit to launch X/Chromium in kiosk mode on boot (Pi Zero W).

---

Why Python over Node on Pi Zero W
---------------------------------

- Pi Zero W (ARMv6) often struggles with modern Node builds; Python 3 is standard, reliable, and lower overhead.
- FastAPI/Flask are sufficient; with `uvicorn` or `waitress`, the backend stays lightweight.
- Frontend remains framework-free to minimize CPU/memory.

---

WMATA API Overview
------------------

- Rail: `StationPrediction.svc` (Next Trains), station metadata, incidents.
- Bus: `NextBusService.svc` (Predictions), route config, stop metadata.
- Auth: Single API key in header (`api_key`) or query param depending on endpoint.
- Rate limits: Cache predictions for 10–20s; align clocks to avoid thrash; exponential backoff on 429/5xx.

Note: WMATA does not provide bikeshare dock data. For accurate bike/dock counts, we integrate Capital Bikeshare’s public GBFS feeds (see below).

Capital Bikeshare (GBFS)
------------------------

- Standard GBFS endpoints provide system and station data. The root feed is:
  - `https://gbfs.capitalbikeshare.com/gbfs/gbfs.json`
- From the root, discover:
  - `station_information.json` (metadata: name, lat/lon, station_id)
  - `station_status.json` (live counts: `num_bikes_available`, `num_docks_available`, and when provided, `num_ebikes_available` or `vehicle_types_available`)
- Approach:
  - Load station information daily; poll station status every 30–60s.
  - Select nearest stations to the configured home location (or favorites).
  - Display concise “bikes | docks” counts with optional e-bikes (⚡) and staleness indicators.

---

Data Model (backend)
--------------------

- Config
  - `home`: `{ lat, lon }`, `radius_m` for nearby queries.
  - `rail`: favorites (station codes), lines filter, refresh interval.
  - `bus`: favorites (stop IDs), routes filter, refresh interval.
  - `ui`: theme, view, rotate_ms.
- Cache
  - `rail_predictions`: keyed by station code.
  - `bus_predictions`: keyed by stop ID.
  - `bike_status`: keyed by bikeshare `station_id` with `bikes` and `docks`.
  - `incidents`: list with severity and affected lines/routes.
  - `meta`: station/stop dictionaries, lazily loaded and refreshed daily.
- Responses (example)
  - `/v1/rail`: `{ updated_at, stations: [{ code, name, lines: [...], arrivals: [{ line, dest, minutes, cars, group }] }] }`
  - `/v1/bus`: `{ updated_at, stops: [{ id, name, routes: [...], arrivals: [{ route, headsign, minutes }] }] }`
  - `/v1/bike`: `{ updated_at, stations: [{ id, name, bikes, docks, distance_m }] }`
  - `/v1/summary`: combined, trimmed to configured favorites/nearby.
  - `/v1/incidents`: current disruptions.
  - `/v1/config`: public-safe subset for the UI.
  - SSE alternative: `/v1/stream` pushing `summary` every N seconds.

---

UI Design Notes (1080p)
-----------------------

- Typography: Large, legible numeric minutes; reduce detail density.
- Color: Use WMATA line colors; ensure WCAG contrast on dark background.
- Layout (1920×1080): Three primary regions
  - Left: Rail board (top 10–12 arrivals across nearest stations; line-colored badges).
  - Center: Bus board (top 12–16 by nearest stops; route-colored badges).
  - Right: “Info” stack — Clock + Weather (top), Service Impacts (middle, scrollable), Bikeshare (bottom).
- Typography: Large, legible minutes; rail/bus rows ~44–52px height; info panel in compact cards.
- Staleness: Badge like `• 28s ago` if data older than 20s.
- Errors: Soft banner if backend unreachable; keep last-good snapshot.
- Power/thermal: Limit DOM churn; requestAnimationFrame batched updates; low CPU.

Note: Dark theme is the only theme and is baked-in for readability and simplicity on 1080p displays.

---

Development Workflow (on Pi 4)
-------------------------------

1) Prepare environment
- Python 3.11+ and `pip`.
- Create venv: `python3 -m venv .venv && source .venv/bin/activate`.
- Install: `pip install fastapi uvicorn pyyaml httpx jinja2`.

2) Scaffold project (proposed layout)

```
metro_clock/
  backend/
    app.py            # FastAPI app; endpoints & SSE
    wmata.py          # Clients and DTOs
    cache.py          # Caching and schedulers
    config.py         # YAML loader & validation
    models.py         # Pydantic models
    templates/
      index.html      # Minimal UI shell
    static/
      app.js          # Polls/SSE + rendering
      styles.css      # High-contrast responsive styles
  config.yaml         # User config (gitignored)
  README.md           # This document
```

3) Run backend locally
- `export WMATA_API_KEY=...`
- `uvicorn backend.app:app --reload --host 0.0.0.0 --port 8080`
- Open `http://<pi4-ip>:8080/` to view the UI.

4) Test with mocked data
- Add a `MOCK=1` env flag to serve fixtures when the API key is absent.
- Unit tests for `wmata.py` transforms; snapshot tests for UI rendering logic.

---

Deployment (Pi Zero W)
----------------------

1) OS setup
- Set Wi‑Fi country with `raspi-config`; enable auto-login to console; set GPU memory to 64MB.
- Install packages: `sudo apt install --no-install-recommends xserver-xorg xinit chromium-browser unclutter`.

2) Backend service
- Install Python deps (same as dev) in a venv under `/opt/metro_clock`.
- Create `systemd` service `metro-clock.service` to run `uvicorn` at boot.

3) Kiosk service
- Create script to start X and Chromium in kiosk:
  - `startx /usr/bin/chromium-browser --kiosk --noerrdialogs --disable-translate --disable-features=TranslateUI --app=http://localhost:8080/`
- Hide cursor with `unclutter -idle 0`.
- Create `systemd` service `kiosk.service` that `After=metro-clock.service`.

4) Logging & watchdog
- Journal limits and logrotate; optional `Restart=always` on both services.

---

Single-Location Setup
---------------------

- During initial setup, run a one-time helper to set home coordinates and write the config.
  - Example: `python -m backend.setup --home 38.8895,-77.0353 --radius 1200`
- After that, the location remains fixed; only favorites/filters might be edited when needed.

Configuration (`config.yaml`)
-----------------------------

```yaml
home:
  lat: 38.8895
  lon: -77.0353
  radius_m: 1200
rail:
  favorites: [A01, C01]     # station codes
  lines: [RD, BL, OR, SV, YL, GR]
  refresh_s: 15
  max_stations: 5           # number of nearby rail stations to show when favorites empty
bus:
  favorites: [1001234, 1005678]  # stop IDs
  extra_stops: []                 # always include these StopIDs in addition to nearby/favorites
  include_near_stations: []       # Metrorail station codes to include nearby bus stops for
  include_near_radius_m: 250      # radius around each station for included stops
  include_near_max_stops: 3       # max stops per station to include
  routes: [S2, S4, 70]
  refresh_s: 15
  max_stops: 3              # number of nearby bus stops to show when favorites empty
  max_arrivals: 8           # maximum arrivals per stop returned by API
bike_share:
  enabled: true
  radius_m: 800
  favorites: [312, 425]     # optional bikeshare station_ids
  refresh_s: 45
weather:
  provider: open-meteo
  refresh_s: 600
ui:
  layout: combined         # combined | rail | bus
  rotate_ms: 0             # 0 disables rotation
```

- Omit `favorites` to select by nearest within `radius_m` (rail/bus) or `bike_share.radius_m` (bikeshare).
- `WMATA_API_KEY` provided via env; do not commit to Git.
- Weather via Open‑Meteo requires no API key. Use the home lat/lon.

Open‑Meteo API (Weather)
------------------------

- Current weather endpoint (example):
  - `https://api.open-meteo.com/v1/forecast?latitude=38.8895&longitude=-77.0353&current_weather=true`
- We cache results for ~10 minutes and surface temperature, wind, and summary.

---

Resilience & Rate Limiting
--------------------------

- Backoff: On 429/5xx, backoff (e.g., 2s, 4s, 8s, max 60s) per endpoint.
- Cohort polling: Align to 10s boundaries to avoid jitter.
- Cache-first: Serve cached predictions instantly; refresh in background.
- Offline: Use last-good with `stale=true` and age indicator.
 - Separate backoff windows per provider (WMATA, GBFS, Open‑Meteo).

---

Security & Privacy
------------------

- No location collection beyond configured static coordinates.
- Store API key in environment or `/etc/default/metro-clock` for systemd.
- Backend binds to `localhost` on the Pi Zero; remote access optional.

---

Future Enhancements
-------------------

- Touch input to toggle views and expand details.
- Heatmap or small map inset for nearby stops.
- Multi-screen/layout presets.
- Home Assistant integration via REST sensor.
- Docker Compose for dev (Pi 4) if desired.

---

Minimal Implementation Plan
---------------------------

1) Implement `config.py`, `wmata.py` (rail/bus) with caching.
2) Add `bikeshare.py` (GBFS) and `weather.py` (Open‑Meteo) clients.
3) Build `/v1/summary` combining rail, bus, bike, incidents, and weather.
4) Serve `index.html`, `styles.css`, `app.js` with combined 1080p layout and polling/SSE.
5) Add kiosk/systemd units, setup helper, and sample `config.yaml`.
6) Polish UI for contrast, staleness, impacts panel, and low-CPU updates.

---

Radius Selection vs. Interactive Setup
--------------------------------------

How radius lookup works
- Data sources: We maintain local, cached metadata with coordinates for:
  - Rail stations (WMATA Stations API; includes `StationTogether` grouping).
  - Bus stops (WMATA GTFS static `stops.txt` cached locally; avoids heavy API scans).
  - Bikeshare stations (Capital Bikeshare GBFS `station_information.json`).
- Distance: Compute great-circle distance from the configured home lat/lon using Haversine (fast enough at this scale). For performance on the Pi Zero, we can use an equirectangular approximation and only switch to Haversine for the top K candidates.
- Selection: Filter by a configurable radius per mode (rail/bus/bikeshare), then sort by distance and take top N (e.g., 2 rail stations, 6–8 bus stops, 2–3 bikeshare docks). Bus stops can be dense; we optionally group by route and direction to avoid clutter.
- Grouping: For rail, use `StationTogether` to merge platforms at the same physical location (e.g., different line codes) into one logical station for display.

Interactive setup (recommended)
- One-time guided selection that writes `config.yaml` and avoids runtime auto-discovery:
  1) Enter home coordinates (or pick on a simple map/shell prompt).
  2) Show nearest rail stations (within `radius_m`), with distance; let you pick 1–3.
  3) Show nearest bus stops; optionally filter by route first, then pick stops/directions.
  4) Show nearest bikeshare docks; pick 1–3.
  5) Confirm and write config; radius lookups are then disabled unless you re-run setup.
- Fallback auto mode: If you skip picking, we auto-select by radius + top N so the display still works immediately.
- Re-run anytime: `python -m backend.setup --reconfigure` to adjust selections later.

Recommendation
- Use interactive setup to lock favorites for this one location. It reduces API calls, avoids noisy bus stops, and yields a cleaner dashboard. Keep radius auto-selection available as a quick-start or fallback.

---

Next Steps (here)
-----------------

- If you want, I can scaffold the backend (FastAPI), add the static UI shell, and include systemd unit templates next. Then we can iterate on the data transforms and UI layout with mocked data before hitting WMATA’s API.

---

Headless Install (OS Image + First Boot)
----------------------------------------

Recommended image
- Raspberry Pi Zero W (production target): `Raspberry Pi OS Lite (32-bit) – Bookworm` (armhf). Stable, minimal, and supported on ARMv6.
- Raspberry Pi 4 (dev box): `Raspberry Pi OS Lite (64-bit) – Bookworm` (aarch64) or keep parity with 32-bit Lite if you prefer identical environments.

Flash with Raspberry Pi Imager
- Use Raspberry Pi Imager on your laptop.
  - Choose OS: as above (Lite/Bookworm).
  - Choose Storage: your SD card.
  - Click the gear (Advanced options) and set:
    - Hostname: `metro-clock`
    - Enable SSH: use password or SSH key
    - Configure Wi‑Fi: SSID, password, and Wi‑Fi country (critical to avoid `rfkill` block)
    - Locale: set timezone and keyboard
  - Write the image. Eject the card.

Manual headless (if not using Advanced options)
- After flashing, re-mount the `boot` partition and create:
  - `ssh` (empty file) to enable SSH
  - `wpa_supplicant.conf` with:
    ```
    country=US
    ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
    update_config=1

    network={
      ssid="YourSSID"
      psk="YourPassword"
      key_mgmt=WPA-PSK
    }
    ```
  - Replace `country`, `ssid`, and `psk` accordingly. This sets Wi‑Fi country to avoid `rfkill`.

First boot
- Power on; find the IP from your router or `raspberrypi.local`/`metro-clock.local`.
- SSH in: `ssh pi@metro-clock.local` (default user is `pi` on Bookworm; set via Imager if needed).
- Verify Wi‑Fi country (if needed): `sudo raspi-config nonint do_wifi_country US`.
- Update base: `sudo apt update && sudo apt full-upgrade -y`.

If Bookworm issues on Zero W
- Rarely, an older Zero W may have better behavior with `Raspberry Pi OS Lite (Legacy) – Bullseye (32-bit)`; only fall back if you hit graphics or Chromium packaging issues.

---

One‑Shot Setup
--------------

Quick start on Raspberry Pi (public repo)
- In Raspberry Pi Imager Advanced options, set Wi‑Fi country, SSID, password, SSH, and paste this into “Run a script”:
  ```bash
  #!/usr/bin/env bash
  set -e
  sudo apt-get update
  sudo apt-get install -y --no-install-recommends git ca-certificates
  sudo -u pi git clone https://github.com/jamesdahall/metro_clock.git /home/pi/metro_clock || true
  ```
- After first boot: SSH in and finish install
  - `cd /home/pi/metro_clock`
  - Minimal deps only: `sudo ./update.sh --apt`
  - Kiosk + services: `sudo ./update.sh --apt --kiosk --install-services --env WMATA_API_KEY=YOUR_KEY`
  - Dev preview: `./dev.sh` then open `http://<pi>:8080/` (requires WMATA key for rail/bus)

Configure API key and config
- WMATA key (for live rail/bus/incidents): `sudo ./update.sh --env WMATA_API_KEY=YOUR_KEY`
- Create a starter config: `./update.sh --write-config --home 38.8895,-77.0353 --radius 1200`
  - Edit `config.yaml` to add favorites:
    - `rail.favorites`: e.g., `[A01, C01]`
    - `bus.favorites`: e.g., `[1001234, 1005678]`
    - `bike_share.favorites`: e.g., `[312, 425]`

Environment and config
- Env file: `/etc/default/metro-clock` (created by `update.sh --install-services`). Add `WMATA_API_KEY=...` and adjust `HOST/PORT` as needed.
- App config: `config.yaml` is optional; auto-nearby selection works without favorites.

Installer notes
- `setup.sh` is an alias of `update.sh` for convenience. Prefer calling `update.sh` directly with flags.
