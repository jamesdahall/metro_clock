import time
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


def _gbfs_feeds():
    def load():
        r = httpx.get("https://gbfs.capitalbikeshare.com/gbfs/gbfs.json", timeout=10)
        r.raise_for_status()
        data = r.json().get("data", {})
        # Prefer English feeds, then fall back to the first language key
        lang = data.get("en")
        if lang is None and isinstance(data, dict) and data:
            # pick first language block
            lang = next(iter(data.values()))
        # Normalize to a list of feed dicts
        if isinstance(lang, dict):
            items = lang.get("feeds", [])
        elif isinstance(lang, list):
            items = lang
        else:
            items = []
        feeds = {}
        for item in items:
            if isinstance(item, dict):
                name = item.get("name")
                url = item.get("url")
                if name and url:
                    feeds[name] = url
        return feeds
    return _cached("gbfs_feeds", 24*3600, load)


def _station_info():
    def load():
        feeds = _gbfs_feeds()
        url = feeds.get("station_information")
        if not url:
            return {}
        r = httpx.get(url, timeout=10)
        r.raise_for_status()
        info = {}
        for s in r.json().get("data", {}).get("stations", []):
            info[str(s.get("station_id"))] = {
                "name": s.get("name"),
                "lat": s.get("lat"),
                "lon": s.get("lon"),
            }
        return info
    return _cached("gbfs_station_info", 24*3600, load)


def bike_status(config):
    # Real GBFS fetch
    def load():
        feeds = _gbfs_feeds()
        url = feeds.get("station_status")
        if not url:
            return []
        r = httpx.get(url, timeout=10)
        r.raise_for_status()
        name_map = _station_info()
        out = []
        favs = list(map(str, config.get("bike_share", {}).get("favorites", [])))
        home = config.get("home", {})
        lat0 = home.get("lat")
        lon0 = home.get("lon")
        radius = float(config.get("bike_share", {}).get("radius_m", 800))
        candidates = []
        for s in r.json().get("data", {}).get("stations", []):
            sid = str(s.get("station_id"))
            meta = name_map.get(sid) or {}
            if favs:
                if sid not in favs:
                    continue
                dist = None
            else:
                if lat0 is None or lon0 is None or meta.get("lat") is None or meta.get("lon") is None:
                    continue
                dist = haversine_m(lat0, lon0, meta.get("lat"), meta.get("lon"))
                if dist > radius:
                    continue
            candidates.append((dist if dist is not None else 1e12, sid, s, meta))
        candidates.sort(key=lambda x: x[0])
        if not favs:
            candidates = candidates[:3]
        for _, sid, s, meta in candidates:
            bikes = s.get("num_bikes_available", 0)
            docks = s.get("num_docks_available", 0)
            eb = s.get("num_ebikes_available")
            if eb is None:
                # GBFS 2.2 vehicle_types_available path
                vta = s.get("vehicle_types_available") or []
                for vt in vta:
                    if (vt.get("vehicle_type_id") or '').lower().find('ebike') != -1:
                        eb = vt.get("count")
                        break
            out.append({
                "id": sid,
                "name": (meta.get("name") if meta else f"Station {sid}"),
                "bikes": bikes,
                "docks": docks,
                "ebikes": eb if eb is not None else 0,
            })
        return out

    stations = _cached("gbfs_status", int(config.get("bike_share", {}).get("refresh_s", 60)), load)
    return {"stations": stations}
