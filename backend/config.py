import os
import yaml


DEFAULT_CONFIG = {
    "home": {"lat": 38.8895, "lon": -77.0353, "radius_m": 1200},
    "rail": {"favorites": [], "lines": ["RD","BL","OR","SV","YL","GR"], "refresh_s": 15, "max_stations": 5},
    "bus": {
        "favorites": [],
        "extra_stops": [],              # Always include these StopIDs
        "include_near_stations": [],     # Metrorail station codes to include nearby stops for
        "include_near_radius_m": 250,    # Radius around each station for nearby bus stops
        "include_near_max_stops": 3,     # Max stops per station to include
        "routes": [],
        "refresh_s": 20,
        "max_stops": 3,
        "max_arrivals": 8,
    },
    "bike_share": {"enabled": True, "radius_m": 800, "favorites": [], "refresh_s": 45},
    "weather": {"provider": "open-meteo", "refresh_s": 600},
    "ui": {"layout": "combined", "rotate_ms": 0},
}


def load_config(path: str = "config.yaml") -> dict:
    if os.path.exists(path):
        with open(path, "r", encoding="utf-8") as f:
            data = yaml.safe_load(f) or {}
    else:
        data = {}
    # merge shallowly with defaults
    cfg = DEFAULT_CONFIG.copy()
    for k, v in (data or {}).items():
        if isinstance(v, dict) and isinstance(cfg.get(k), dict):
            merged = cfg[k].copy()
            merged.update(v)
            cfg[k] = merged
        else:
            cfg[k] = v
    return cfg


# Mock mode has been removed to avoid false positives.
