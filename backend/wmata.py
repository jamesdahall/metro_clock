import time
import os
import httpx
from .util import haversine_m

_cache = {}


def _cached(key, ttl_s, loader):
    now = time.time()
    entry = _cache.get(key)
    if entry and now - entry[0] < ttl_s:
        return entry[1]
    val = loader()
    _cache[key] = (now, val)
    return val


def _wmata_headers():
    return {"api_key": os.getenv("WMATA_API_KEY", "")}


def _stations_meta():
    def load():
        url = "https://api.wmata.com/Rail.svc/json/jStations"
        r = httpx.get(url, headers=_wmata_headers(), timeout=10)
        r.raise_for_status()
        data = r.json().get("Stations", [])
        meta = {}
        for s in data:
            code = s.get("Code")
            if not code:
                continue
            meta[code] = {
                "name": s.get("Name"),
                "lat": s.get("Lat"),
                "lon": s.get("Lon"),
            }
        return meta

    return _cached("stations_meta", 24 * 3600, load)


def _nearest_rail_codes(config):
    max_n = int(config.get("rail", {}).get("max_stations", 5))
    meta = _stations_meta()
    home = config.get("home", {})
    lat = home.get("lat")
    lon = home.get("lon")
    radius = float(home.get("radius_m", 1200))
    if lat is None or lon is None:
        return []
    within = []
    all_dist = []
    for code, m in meta.items():
        if m.get("lat") is None or m.get("lon") is None:
            continue
        d = haversine_m(lat, lon, m["lat"], m["lon"])
        all_dist.append((d, code))
        if d <= radius:
            within.append((d, code))
    within.sort(key=lambda x: x[0])
    if within:
        return [code for _, code in within[:max_n]]
    # Fallback: take nearest overall if none inside radius
    all_dist.sort(key=lambda x: x[0])
    return [code for _, code in all_dist[:max_n]]


def rail_predictions(config):
    key = os.getenv("WMATA_API_KEY", "")
    if not key:
        raise RuntimeError("WMATA_API_KEY not set")
    favorites = config.get("rail", {}).get("favorites", []) or _nearest_rail_codes(config)
    ttl = int(config.get("rail", {}).get("refresh_s", 15))
    meta = _stations_meta() if favorites else {}

    stations = []
    for code in favorites:
        def load(code=code):
            url = f"https://api.wmata.com/StationPrediction.svc/json/GetPrediction/{code}"
            r = httpx.get(url, headers=_wmata_headers(), timeout=10)
            r.raise_for_status()
            trains = []
            for t in r.json().get("Trains", []):
                minutes = t.get("Min")
                try:
                    minutes = int(minutes)
                except Exception:
                    minutes = minutes or "--"
                trains.append({
                    "line": t.get("Line"),
                    "dest": t.get("DestinationName"),
                    "minutes": minutes,
                    "cars": _safe_int(t.get("Car")),
                })
            return trains

        arrivals = _cached(f"rail_{code}", ttl, load)
        name = meta.get(code, {}).get("name") if meta else None
        stations.append({"code": code, "name": name or code, "arrivals": arrivals})

    return {"stations": stations}


def _safe_int(x):
    try:
        return int(x)
    except Exception:
        return None


def bus_predictions(config):
    key = os.getenv("WMATA_API_KEY", "")
    if not key:
        raise RuntimeError("WMATA_API_KEY not set")
    bus_cfg = config.get("bus", {})
    favorites = list(map(str, bus_cfg.get("favorites", [])))
    # Merge explicit extra stops
    extras = list(map(str, bus_cfg.get("extra_stops", [])))
    favorites += extras
    names_map = {}

    # Include stops near specified rail stations
    include_stations = bus_cfg.get("include_near_stations", [])
    if include_stations:
        radius_s = int(bus_cfg.get("include_near_radius_m", 250))
        per_station = int(bus_cfg.get("include_near_max_stops", 3))
        meta = _stations_meta()
        for scode in include_stations:
            m = meta.get(scode)
            if not m or m.get("lat") is None or m.get("lon") is None:
                continue
            lat_s, lon_s = m["lat"], m["lon"]
            url = f"https://api.wmata.com/Bus.svc/json/jStops?lat={lat_s}&lon={lon_s}&radius={radius_s}"
            rr = httpx.get(url, headers=_wmata_headers(), timeout=10)
            rr.raise_for_status()
            stops = rr.json().get("Stops", [])
            stops_sorted = sorted(stops, key=lambda s: s.get("Distance", 999999))[:per_station]
            for s in stops_sorted:
                sid = s.get("StopID")
                if sid is None:
                    continue
                sid = str(sid)
                favorites.append(sid)
                names_map[sid] = s.get("Name") or f"Stop {sid}"

    # If still none, discover nearby stops via home lat/lon
    if not favorites:
        # discover nearby stops via NextBus jStops
        home = config.get("home", {})
        lat = home.get("lat")
        lon = home.get("lon")
        radius = int(home.get("radius_m", 1200))
        if lat is not None and lon is not None:
            def load_nb():
                limit = int(config.get("bus", {}).get("max_stops", 3))
                # Try increasing radius if none found; use Bus.svc for jStops (NextBus jStops is not available)
                for rad in (radius, max(radius, 3000), max(radius, 5000)):
                    url = f"https://api.wmata.com/Bus.svc/json/jStops?lat={lat}&lon={lon}&radius={rad}"
                    rr = httpx.get(url, headers=_wmata_headers(), timeout=10)
                    rr.raise_for_status()
                    stops = rr.json().get("Stops", [])
                    if stops:
                        stops_sorted = sorted(stops, key=lambda s: s.get("Distance", 999999))[:limit]
                        out = []
                        for s in stops_sorted:
                            sid = s.get("StopID")
                            if sid is None:
                                continue
                            sid = str(sid)
                            name = s.get("Name") or f"Stop {sid}"
                            out.append((sid, name))
                        return out
                return []

            favs = _cached("bus_nearby", 600, load_nb)
            favorites = [sid for sid, _ in favs]
            names_map = {sid: nm for sid, nm in favs}
    # Deduplicate, preserve order
    seen = set()
    uniq_favs = []
    for sid in favorites:
        if sid not in seen:
            seen.add(sid)
            uniq_favs.append(sid)
    favorites = uniq_favs
    ttl = int(config.get("bus", {}).get("refresh_s", 20))
    stops = []
    max_arrivals = int(config.get("bus", {}).get("max_arrivals", 8))
    for stop_id in favorites:
        def load(stop_id=stop_id):
            url = f"https://api.wmata.com/NextBusService.svc/json/jPredictions?StopID={stop_id}"
            r = httpx.get(url, headers=_wmata_headers(), timeout=10)
            r.raise_for_status()
            preds = []
            for p in r.json().get("Predictions", []):
                preds.append({
                    "route": p.get("RouteID"),
                    "headsign": p.get("DirectionText") or p.get("TripHeadsign"),
                    "minutes": _safe_int(p.get("Minutes")),
                })
            name = (r.json().get("StopName") or f"Stop {stop_id}")
            return {"name": name, "arrivals": preds[:max_arrivals]}

        entry = _cached(f"bus_{stop_id}", ttl, load)
        nm = entry.get("name") or names_map.get(stop_id) or f"Stop {stop_id}"
        stops.append({"id": stop_id, "name": nm, "arrivals": entry.get("arrivals", [])})

    return {"stops": stops}


def incidents(config):
    key = os.getenv("WMATA_API_KEY", "")
    if not key:
        raise RuntimeError("WMATA_API_KEY not set")
    def load():
        url = "https://api.wmata.com/Incidents.svc/json/Incidents"
        r = httpx.get(url, headers=_wmata_headers(), timeout=10)
        r.raise_for_status()
        out = []
        for i in r.json().get("Incidents", []):
            out.append({
                "type": i.get("IncidentType", "rail").lower(),
                "severity": (i.get("Severity") or "info").lower(),
                "text": i.get("Description") or "Service advisory",
            })
        return out

    return _cached("incidents", 60, load)
