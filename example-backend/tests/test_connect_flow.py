"""Pairing + direct flows through the real routes, with faked transport/dispatch
(no network). Locks in the connection contract and the register/dispatch wiring."""

from fastapi.testclient import TestClient

from app.config import settings
from app.main import app
from app.registry import InMemoryRegistry

AUTH = {"Authorization": f"Bearer {settings.engine_api_key}"}


class _FakeRoom:
    def __init__(self, name, url):
        self.name = name
        self.url = url


class FakeDaily:
    async def create_room(self, *, exp_secs, name=None):
        return _FakeRoom("room-abc", "https://x.daily.co/room-abc")

    async def mint_token(self, room_url, *, ttl_secs, owner):
        return "token-bot" if owner else "token-app"

    async def delete_room_by_url(self, room_url):
        pass


class FakeDispatcher:
    def __init__(self):
        self.calls = []

    async def dispatch(self, *, room_key, agent_id, transport, bot_argv, cleanup=None):
        self.calls.append((room_key, agent_id, transport, tuple(bot_argv)))
        return 12345


def test_connect_pairing_daily_dispatches_and_returns_contract():
    with TestClient(app) as c:
        app.state.daily = FakeDaily()
        app.state.dispatcher = FakeDispatcher()

        r = c.post("/connect", json={"agent_id": "loopback", "transport": "daily"}, headers=AUTH)
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["transport"] == "daily"
        assert body["agent_id"] == "loopback"
        assert body["connection"] == {
            "room_url": "https://x.daily.co/room-abc",
            "token": "token-app",
        }
        assert body["expires_at"] is not None  # pairing → short-lived

        # The bot was dispatched into the room with the BOT token (not the app token).
        calls = app.state.dispatcher.calls
        assert len(calls) == 1
        room_key, agent_id, transport, argv = calls[0]
        assert (room_key, agent_id, transport) == ("room-abc", "loopback", "daily")
        assert "token-bot" in argv and "--room-url" in argv


def test_credentials_direct_registers_room_without_dispatch():
    with TestClient(app) as c:
        app.state.daily = FakeDaily()
        app.state.dispatcher = FakeDispatcher()
        app.state.registry = InMemoryRegistry()

        r = c.post("/credentials", json={"agent_id": "live", "transport": "daily"}, headers=AUTH)
        assert r.status_code == 200, r.text

        # No dispatch at provision time (that happens later via webhook).
        assert app.state.dispatcher.calls == []
        # Room is registered for the webhook to find, with its URL stored.
        rec = app.state.registry._rooms.get("room-abc")
        assert rec is not None
        assert rec.agent_id == "live"
        assert rec.room_url == "https://x.daily.co/room-abc"


def test_live_without_model_keys_returns_503_not_silent_room(monkeypatch):
    # Requesting `live` with a missing model key must fail clean BEFORE minting creds —
    # otherwise the client connects to a room whose bot crashes on launch (silence).
    monkeypatch.setattr(settings, "groq_api_key", None)
    with TestClient(app) as c:
        app.state.daily = FakeDaily()
        app.state.dispatcher = FakeDispatcher()

        r = c.post("/connect", json={"agent_id": "live", "transport": "daily"}, headers=AUTH)
        assert r.status_code == 503, r.text
        assert app.state.dispatcher.calls == []  # nothing dispatched, no room minted
