DC Metro (WMATA) + Bikeshare + Weather Display
==============================================

A lightweight, kiosk-style dashboard showing WMATA rail and bus arrivals, Capital Bikeshare dock availability, current weather, and service impacts — optimized for a 1920×1080 display. Designed to run 24/7 on a Raspberry Pi Zero W (development on a Raspberry Pi 4).

---

Table of Contents
-----------------

- Install (curl)
- Goals
- Features
- Architecture
- WMATA API Overview
- Capital Bikeshare (GBFS)
- Data Model (backend)
- UI Design Notes (1080p)
- Deployment (Pi Zero W)
- Single-Location Setup
- Configuration (config.yaml)
- Open‑Meteo API (Weather)
- Resilience & Rate Limiting
- Security & Privacy
- Future Enhancements
- Minimal Implementation Plan
- Radius Selection vs. Interactive Setup
- Local Development (optional)
- Environment and config
- Installer notes
- Planned Features
- Troubleshooting

---

Install (clean image)
---------------------

Recommended, minimal-typing install on Raspberry Pi OS Lite (Bookworm):

1) Prep the OS
   - Set Wi‑Fi country (unblocks Wi‑Fi): `sudo raspi-config nonint do_wifi_country US`
   - Update apt: `sudo apt-get update`

2) Get the code and run the updater
   - `git clone https://github.com/jamesdahall/metro_clock.git && cd metro_clock`
   - `sudo ./update.sh --apt --kiosk --install-services --env WMATA_API_KEY=YOUR_KEY`

3) Verify
   - Backend: `systemctl status metro-clock.service` (listens on 127.0.0.1:8080)
   - Kiosk: `systemctl status metro-kiosk.service` (starts X on TTY1)
   - For remote testing: set `HOST=0.0.0.0` in `/etc/default/metro-clock` and visit `http://<pi-ip>:8080/`.

Notes
- On Pi Zero W (ARMv6), Chromium requires NEON and won’t run. The installer auto‑selects `surf` and launches it via a robust `.xinitrc` session with `matchbox-window-manager`.
- On Pi 3/4/Zero 2 (ARMv7+), Chromium is used by default; override with `--browser surf` if preferred.
- The kiosk uses `xinit` + `.xinitrc` by default; switch to a simple wrapper with `--kiosk-session wrapper` if you really need it.
- Xorg permissions are configured (`/etc/Xwrapper.config`), and `getty@tty1` is disabled to avoid TTY contention.

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
- Service impacts: Prominent panel for WMATA incidents/disruptions (rail and bus).
- Bikeshare counts: Capital Bikeshare dock status via GBFS (bikes, docks, and e-bikes when available).
- Clock and weather: Always-visible clock; current conditions + short summary via Open‑Meteo.
- Favorites & filters: Pin specific stations/stops; radius-based auto-selection optional. Route/line filters planned.
- Performance-aware UI: Large fonts, dark theme, low reflow; 1080p-optimized.
- Auto start: Boots into Chromium kiosk; watchdog restarts on crash.

---

Architecture
------------

- Backend: Python (FastAPI or Flask) service on the Pi
  - Fetches WMATA data on a short interval (e.g., every 10–20s), caches in memory.
  - Exposes a tiny REST endpoint to the frontend (SSE planned as an optional enhancement).
  - Handles rate-limits, retries, and backoff; consolidates/massages data.
  - Optional SQLite for static reference data (station/stop metadata) and durable cache.
- Integrations: Lightweight HTTP clients using `httpx`
  - WMATA Rail and Bus predictions.
  - Capital Bikeshare GBFS (station information/status) for live bike/dock counts.
  - Open‑Meteo weather API for current conditions (no API key required).
- Frontend: Minimal static page with vanilla JS
  - Polls backend JSON for live updates (SSE planned).
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
  - (Planned) SSE alternative: `/v1/stream` pushing `summary` every N seconds.

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

Local Development (optional)
---------------------------

For contributors. End‑users should use the curl installer above.

- Prepare: `python3 -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt`
- Run: `export WMATA_API_KEY=... && ./dev.sh`
- Open: `http://<device-ip>:8080/`
- Testing: Use live data or add local fixtures.

---

Deployment (Pi Zero W)
----------------------

The curl installer sets up systemd services and kiosk mode for you when `--full` is used. Manual deployment steps are no longer required.

Post‑install tips
- Start/stop services: `sudo systemctl start|stop metro-clock.service metro-kiosk.service`
- Enable at boot: handled by installer; verify with `systemctl is-enabled ...`
- Display timers and weekly reboot are installed by default; see `update.sh` for schedules.

---

Single-Location Setup
---------------------

- During initial setup, use the curl installer (two‑step, recommended) or run the in‑repo interactive setup.
  - Two‑step curl installer (see Install above)
  - In‑repo interactive: `sudo ./update.sh` (guided)
- Non-interactive alternative to create a starter config:
  - `./update.sh --write-config --home 38.8895,-77.0353 --radius 1200`
- After that, the location remains fixed; only favorites might be edited when needed.

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
 - Note: `rail.lines` and `bus.routes` are planned filters; current implementation prioritizes favorites/nearby selection.

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
4) Serve `index.html`, `styles.css`, `app.js` with combined 1080p layout and JSON polling (SSE planned).
5) Add kiosk/systemd units, setup helper, and sample `config.yaml`.
6) Polish UI for contrast, staleness, impacts panel, and low-CPU updates.

---

Radius Selection vs. Interactive Setup
--------------------------------------

How radius lookup works
- Data sources: We maintain local, cached metadata with coordinates for:
- Rail stations (WMATA Stations API).
  - Bus stops (WMATA GTFS static `stops.txt` cached locally; avoids heavy API scans).
  - Bikeshare stations (Capital Bikeshare GBFS `station_information.json`).
- Distance: Compute great-circle distance from the configured home lat/lon using Haversine (fast enough at this scale). For performance on the Pi Zero, we can use an equirectangular approximation and only switch to Haversine for the top K candidates.
- Selection: Filter by a configurable radius per mode (rail/bus/bikeshare), then sort by distance and take top N (e.g., 2 rail stations, 6–8 bus stops, 2–3 bikeshare docks). Bus stops can be dense; we optionally group by route and direction to avoid clutter.

Interactive setup (recommended)
- One-time guided selection that writes `config.yaml` and avoids runtime auto-discovery:
  1) Enter home coordinates (or pick on a simple map/shell prompt).
  2) Show nearest rail stations (within `radius_m`), with distance; let you pick 1–3.
  3) Show nearest bus stops; optionally filter by route first, then pick stops/directions.
  4) Show nearest bikeshare docks; pick 1–3.
  5) Confirm and write config; radius lookups are then disabled unless you re-run setup.
- Fallback auto mode: If you skip picking, we auto-select by radius + top N so the display still works immediately.
- Re-run anytime: `sudo ./update.sh` to adjust selections later.

Recommendation
- Use interactive setup to lock favorites for this one location. It reduces API calls, avoids noisy bus stops, and yields a cleaner dashboard. Keep radius auto-selection available as a quick-start or fallback.

---

 

<!-- Headless image preparation details removed to reduce confusion; use Raspberry Pi Imager defaults and ensure Wi‑Fi country is set, then run the curl installer. -->

Install Options
---------------

Use the curl installer flags to tailor behavior:
- `--wizard`: Ask all questions up front with validation.
- `--full`: Install minimal deps, kiosk, and services (non‑interactive apt).
- `--kiosk-services`: Equivalent to `--kiosk --services`.
- `--bg`: Run install in background after confirmation; logs at `/var/log/metro-install.log`.

Environment and config
----------------------
- Env file: `/etc/default/metro-clock` (created by the installer). Holds `WMATA_API_KEY`, `HOST`, and `PORT`.
- App config: `config.yaml` is optional; auto‑nearby selection works without favorites.

Installer notes
---------------
- Recommended: curl‑based `install.sh` with `--wizard`. `update.sh` (interactive with no flags, or via flags) remains for advanced use.

Planned Features
----------------

- Offline/poor network mode with last‑known predictions, staleness badges, and age indicator.
- Retry/backoff strategy with cohort polling alignment (e.g., 10s boundaries).
- Server‑Sent Events (SSE) stream endpoint as an alternative to polling.
- Enforce route and line filters in backend transforms (rail/bus).
- Background refreshers to update caches outside the request path.
- UI performance improvements (requestAnimationFrame batching and minimal DOM diffs).


Troubleshooting
---------------

- Wi‑Fi blocked by rfkill: Set Wi‑Fi country once, then reboot.
  - `sudo raspi-config nonint do_wifi_country US`
- WMATA 401/403 errors: Ensure `WMATA_API_KEY` is set and valid in the environment or `/etc/default/metro-clock`.
- Chromium package name differs: Some releases use `chromium` instead of `chromium-browser`. The installer auto-detects.
- Blank data panels: Without an API key, rail/bus calls fail; weather and bikeshare should still populate.
- Slow Zero W performance: Prefer polling every 10–20s; keep the UI open in kiosk only.
- Pi Zero W + Chromium: Current Chromium requires NEON and won’t run on ARMv6. The installer auto‑selects `surf` on ARMv6.
- Kiosk shows blank screen but processes are running: Try a safer mode first (1280×720@60). The default `.xinitrc` asserts this; you can switch to 1080p30 by adding `xrandr --output HDMI-1 --mode 1920x1080 --rate 30` inside `~/.xinitrc`.
- Xorg permissions / TTY contention: Ensure `/etc/Xwrapper.config` contains `allowed_users=anybody`; disable `getty@tty1.service`.
