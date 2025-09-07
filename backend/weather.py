import time
import httpx

_cache = {}


def _cached(key, ttl_s, loader):
    now = time.time()
    entry = _cache.get(key)
    if entry and now - entry[0] < ttl_s:
        return entry[1]
    val = loader()
    _cache[key] = (now, val)
    return val


def current_weather(config):
    # Open-Meteo current weather (Fahrenheit, mph)
    home = config.get("home", {})
    lat = home.get("lat", 38.8895)
    lon = home.get("lon", -77.0353)
    def load():
        url = (
            "https://api.open-meteo.com/v1/forecast"
            f"?latitude={lat}&longitude={lon}"
            "&current_weather=true&temperature_unit=fahrenheit&windspeed_unit=mph"
        )
        r = httpx.get(url, timeout=10)
        r.raise_for_status()
        cw = r.json().get("current_weather") or {}
        temp_f = cw.get("temperature")
        wind_mph = cw.get("windspeed")
        code = cw.get("weathercode")
        return {
            "temp_f": temp_f,
            "wind_mph": wind_mph,
            "summary": _wm_summary(code),
            "icon": _wm_icon(code),
        }
    return _cached("weather_current", int(config.get("weather", {}).get("refresh_s", 600)), load)


def hourly_forecast(config, hours=12):
    home = config.get("home", {})
    lat = home.get("lat", 38.8895)
    lon = home.get("lon", -77.0353)
    def load():
        url = (
            "https://api.open-meteo.com/v1/forecast"
            f"?latitude={lat}&longitude={lon}"
            "&hourly=temperature_2m,precipitation_probability,weathercode"
            "&forecast_days=2&timezone=auto&temperature_unit=fahrenheit&windspeed_unit=mph"
        )
        r = httpx.get(url, timeout=10)
        r.raise_for_status()
        data = r.json().get("hourly", {})
        times = data.get("time", [])
        temps = data.get("temperature_2m", [])
        pops = data.get("precipitation_probability", [])
        codes = data.get("weathercode", [])
        out = []
        now = time.time()
        def parse_iso(ts):
            try:
                y=int(ts[0:4]); m=int(ts[5:7]); d=int(ts[8:10]); hh=int(ts[11:13]); mm=int(ts[14:16])
                import datetime
                dt = datetime.datetime(y,m,d,hh,mm)
                return int(dt.timestamp())
            except Exception:
                return None
        for i in range(min(len(times), len(temps), len(pops), len(codes))):
            ts = parse_iso(times[i])
            if ts is None:
                continue
            if ts + 3600 < now:
                continue
            out.append({
                "time": ts,
                "temp_f": temps[i],
                "pop": pops[i],
                "icon": _wm_icon(codes[i]),
                "summary": _wm_summary(codes[i]),
            })
            if len(out) >= hours:
                break
        return out
    return _cached("weather_hourly", 600, load)


def weather_alerts(config):
    home = config.get("home", {})
    lat = home.get("lat", 38.8895)
    lon = home.get("lon", -77.0353)
    def load():
        headers = {"User-Agent": "metro-clock/1.0 (+https://github.com/jamesdahall/metro_clock)"}
        url = f"https://api.weather.gov/alerts/active?point={lat},{lon}"
        r = httpx.get(url, headers=headers, timeout=10)
        r.raise_for_status()
        feats = (r.json().get("features") or [])
        out = []
        for f in feats:
            p = f.get("properties", {})
            out.append({
                "event": p.get("event"),
                "severity": (p.get("severity") or ""),
                "headline": p.get("headline") or (p.get("parameters", {}).get("NWSheadline", [None])[0]),
                "ends": p.get("ends"),
            })
        return out[:5]
    return _cached("weather_alerts", 300, load)


def _wm_summary(code):
    # Minimal mapping for common codes
    mapping = {
        0: "Clear",
        1: "Mainly clear",
        2: "Partly cloudy",
        3: "Overcast",
        45: "Fog",
        48: "Depositing rime fog",
        51: "Light drizzle",
        53: "Drizzle",
        55: "Heavy drizzle",
        61: "Light rain",
        63: "Rain",
        65: "Heavy rain",
        71: "Light snow",
        73: "Snow",
        75: "Heavy snow",
        95: "Thunderstorm",
        96: "Thunderstorm w/ hail",
        99: "Thunderstorm w/ heavy hail",
    }
    return mapping.get(code, "Weather")


def _wm_icon(code):
    # Emoji icon mapping for common Open-Meteo weather codes
    if code is None:
        return "🌡️"
    try:
        c = int(code)
    except Exception:
        return "🌡️"
    if c == 0:
        return "☀️"
    if c in (1,):
        return "🌤️"
    if c in (2,):
        return "⛅"
    if c in (3,):
        return "☁️"
    if c in (45, 48):
        return "🌫️"
    if c in (51, 53, 55, 61, 63, 65):
        return "🌧️"
    if c in (71, 73, 75):
        return "🌨️"
    if c in (95, 96, 99):
        return "⛈️"
    return "🌡️"
