# the web server part
# fastapi seemed easier than flask for async stuff so here we are
import ipaddress
import secrets

from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse, StreamingResponse, JSONResponse
from fastapi.templating import Jinja2Templates
from starlette.middleware.base import BaseHTTPMiddleware
from pathlib import Path

from .detect import full_detect
from .installer import stream_install
from .validators import validate_config

app = FastAPI(title="VeilNet", docs_url=None, redoc_url=None)

BASE_DIR = Path(__file__).parent
templates = Jinja2Templates(directory=str(BASE_DIR / "templates"))

# every rfc1918 range i could find plus localhost and link-local
# if youre hitting this from the internet something has gone very wrong
_PRIVATE_NETS = [
    ipaddress.ip_network("10.0.0.0/8"),
    ipaddress.ip_network("172.16.0.0/12"),
    ipaddress.ip_network("192.168.0.0/16"),
    ipaddress.ip_network("127.0.0.0/8"),
    ipaddress.ip_network("169.254.0.0/16"),
    ipaddress.ip_network("::1/128"),
    ipaddress.ip_network("fe80::/10"),
    ipaddress.ip_network("fc00::/7"),
]


def _is_private(ip_str: str) -> bool:
    try:
        addr = ipaddress.ip_address(ip_str)
        return any(addr in net for net in _PRIVATE_NETS)
    except ValueError:
        return False


# only let people on the local network use this
# its basically a bouncer
class LANOnlyMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        # nginx puts the real ip here
        forwarded = request.headers.get("x-forwarded-for")
        if forwarded:
            client_ip = forwarded.split(",")[0].strip()
        else:
            client_ip = request.client.host if request.client else "127.0.0.1"

        if not _is_private(client_ip):
            return JSONResponse(
                {"error": "Access denied: VeilNet wizard is LAN-only"},
                status_code=403,
            )
        return await call_next(request)


# csrf protection so random websites cant post to our api
# looked up "double submit cookie" like 3 times before i got it, still not sure I do
class CSRFMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        if request.method in ("POST", "PUT", "DELETE", "PATCH"):
            cookie_token = request.cookies.get("veilnet_csrf")
            header_token = request.headers.get("x-csrf-token")
            if not cookie_token or not header_token or cookie_token != header_token:
                return JSONResponse(
                    {"error": "CSRF token missing or invalid"},
                    status_code=403,
                )
        return await call_next(request)


app.add_middleware(CSRFMiddleware)
app.add_middleware(LANOnlyMiddleware)


@app.get("/", response_class=HTMLResponse)
async def index(request: Request):
    return templates.TemplateResponse("index.html", {"request": request})


@app.get("/api/csrf-token")
async def csrf_token():
    """gives the browser a token it has to send back with posts"""
    token = secrets.token_urlsafe(32)
    response = JSONResponse({"token": token})
    response.set_cookie(
        "veilnet_csrf",
        token,
        httponly=False,  # js needs to read this, yes i know
        samesite="strict",
        secure=False,  # lan only, no tls
    )
    return response


@app.get("/api/detect")
async def detect():
    """figures out what pi you have and whats plugged into it"""
    try:
        result = full_detect()
        return JSONResponse(result)
    except Exception as e:
        return JSONResponse({"error": str(e)}, status_code=500)


@app.post("/api/install")
async def install(request: Request):
    """the big one. takes the config, runs all the scripts, streams progress back."""
    try:
        config = await request.json()
    except Exception:
        return JSONResponse({"error": "Invalid config"}, status_code=400)

    # check it again here because i dont trust the frontend
    clean_config, errors = validate_config(config)
    if errors:
        return JSONResponse({"error": "Validation failed", "details": errors}, status_code=400)

    async def event_stream():
        async for chunk in stream_install(clean_config):
            yield chunk

    return StreamingResponse(
        event_stream(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "X-Accel-Buffering": "no",  # nginx buffers sse by default which breaks everything
        },
    )


@app.get("/api/status")
async def status():
    """checks which services actually started. for the status page after reboot."""
    from .detect import detect_installed_services
    try:
        return JSONResponse(detect_installed_services())
    except Exception as e:
        return JSONResponse({"error": str(e)}, status_code=500)


@app.get("/api/interfaces")
async def interfaces():
    """returns network interfaces so the wizard can show a picker"""
    from .detect import detect_interfaces
    try:
        return JSONResponse(detect_interfaces())
    except Exception as e:
        return JSONResponse({"error": str(e)}, status_code=500)
