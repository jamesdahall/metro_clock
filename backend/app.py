from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from jinja2 import Environment, FileSystemLoader, select_autoescape
import os
import time
from .config import load_config
from .wmata import rail_predictions, bus_predictions, incidents
from .bikeshare import bike_status
from .weather import current_weather
import logging

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TEMPLATES_DIR = os.path.join(BASE_DIR, 'backend', 'templates')
STATIC_DIR = os.path.join(BASE_DIR, 'backend', 'static')

env = Environment(
    loader=FileSystemLoader(TEMPLATES_DIR),
    autoescape=select_autoescape(['html', 'xml'])
)

app = FastAPI()
app.mount('/static', StaticFiles(directory=STATIC_DIR), name='static')


def build_summary(cfg: dict, mock: bool):
    now = int(time.time())
    return {
        "updated_at": now,
        "rail": rail_predictions(cfg, mock=mock),
        "bus": bus_predictions(cfg, mock=mock),
        "bike": bike_status(cfg, mock=mock) if cfg.get("bike_share", {}).get("enabled", True) else {"stations": []},
        "weather": current_weather(cfg, mock=mock),
        "incidents": incidents(cfg, mock=mock),
    }


@app.get('/', response_class=HTMLResponse)
async def index(request: Request):
    template = env.get_template('index.html')
    html = template.render()
    return HTMLResponse(content=html)


@app.get('/v1/summary', response_class=JSONResponse)
async def summary():
    cfg = load_config()
    errors = []

    def safe(name, callable_, fallback):
        try:
            return callable_()
        except Exception as e:
            logging.exception("%s provider error: %s", name, e)
            errors.append(f"{name}: {e}")
            return fallback

    rail = safe("wmata_rail", lambda: rail_predictions(cfg), {"stations": []})
    bus = safe("wmata_bus", lambda: bus_predictions(cfg), {"stops": []})
    bike = {"stations": []}
    if cfg.get("bike_share", {}).get("enabled", True):
        bike = safe("bikeshare", lambda: bike_status(cfg), {"stations": []})
    from .weather import current_weather, hourly_forecast, weather_alerts
    weather_now = safe("weather_now", lambda: current_weather(cfg), {})
    weather_hourly = safe("weather_hourly", lambda: hourly_forecast(cfg, hours=12), [])
    alerts = safe("weather_alerts", lambda: weather_alerts(cfg), [])
    inc = safe("wmata_incidents", lambda: incidents(cfg), [])

    return JSONResponse(content={
        "updated_at": int(time.time()),
        "rail": rail,
        "bus": bus,
        "bike": bike,
        "weather": {"now": weather_now, "hourly": weather_hourly, "alerts": alerts},
        "incidents": inc,
        "errors": errors,
    })
