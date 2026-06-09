"""The always-on dispatcher (FastAPI).

Mints credentials, receives SFU webhooks, and dispatches bot subprocesses. Must
not sleep on Railway (it serves /connect and webhooks promptly at any time).
"""

from __future__ import annotations

import ssl
from contextlib import asynccontextmanager

import aiohttp
import certifi
from fastapi import FastAPI

from app.config import settings
from app.dispatch import Dispatcher
from app.obs import event, get_logger, setup_logging
from app.registry import InMemoryRegistry
from app.routes import admin, connect, webhooks
from app.transports.daily import DailyService


def _make_livekit():
    """Build the LiveKit service if fully configured, else None."""
    if not (settings.livekit_api_key and settings.livekit_api_secret and settings.livekit_url):
        return None
    from app.transports.livekit import LiveKitService

    return LiveKitService()


@asynccontextmanager
async def lifespan(app: FastAPI):
    setup_logging()
    log = get_logger("main")

    # Fail fast on a misconfigured deploy. Every billable endpoint needs this; without
    # it the container would boot, pass /health, and 500 on every real request — a
    # silent trap. Crash on startup instead so the deploy never goes "green" broken.
    settings.require("engine_api_key")

    # Verify TLS against certifi's CA bundle rather than the OS trust store. The
    # python.org / uv Python builds (notably on macOS) don't read the system store,
    # so the default aiohttp context fails to verify api.daily.co. certifi is
    # self-contained and works the same on macOS dev and Linux prod.
    ssl_context = ssl.create_default_context(cafile=certifi.where())
    session = aiohttp.ClientSession(connector=aiohttp.TCPConnector(ssl=ssl_context))
    registry = InMemoryRegistry()
    app.state.session = session
    app.state.registry = registry
    app.state.dispatcher = Dispatcher(registry)
    app.state.daily = DailyService(session) if settings.daily_api_key else None
    app.state.livekit = _make_livekit()

    event(
        log,
        "engine.started",
        daily=bool(app.state.daily),
        livekit=bool(app.state.livekit),
        default_transport=settings.default_transport,
    )
    try:
        yield
    finally:
        await session.close()
        event(log, "engine.stopped")


app = FastAPI(title="Conduit Engine", version="0.1.0", lifespan=lifespan)

app.include_router(connect.router)
app.include_router(webhooks.router)
app.include_router(admin.router)


@app.get("/health")
async def health():
    """Liveness for Railway and keep-warm. No auth."""
    return {"status": "ok"}
