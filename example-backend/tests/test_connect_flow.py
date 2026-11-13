"""Pairing + direct flows through the real routes, with faked transport/dispatch
(no network). Locks in the connection contract and the register/dispatch wiring."""

import asyncio

from fastapi.testclient import TestClient

from app.config import settings
from app.main import app

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


class FakeLiveKit:
    url = "wss://example.livekit.cloud"

    def user_token(self, room_name, *, ttl_secs):
        return "lk-token-app"

    def agent_token(self, room_name, *, ttl_secs):
        return "lk-token-bot"


class FakeDispatcher:
    def __init__(self):
        self.calls = []
        self.envs = []  # the bot_env of each dispatch
        self.controls = []
        self.sent = []  # (room_key, control line)
        self.disconnected = []
        self.cancels = []  # rooms asked to cancel their ring bot
        # What a ring bot answers a cancel with: "ended", "refused" (the call was
        # answered) or None (it can't be reached; the caller then force-ends it).
        self.cancel_outcome = "ended"
        self.reports_joined = []  # report_joined, per dispatch
        self.alive = set()  # rooms with a running bot
        self.waits = []  # (room_key, timeout) per wait_joined
        # What wait_joined says: "joined" at once, "exited" at once, or "timeout"
        # after the timeout (a bot that never joins). on_wait runs first.
        self.join_outcome = "joined"
        self.on_wait = None

    async def send_control(self, room_key, message):
        self.sent.append((room_key, message))
        return True

    async def disconnect(self, room_key):
        self.disconnected.append(room_key)
        self.alive.discard(room_key)
        return True

    async def cancel_ring_bot(self, room_key):
        self.cancels.append(room_key)
        if self.cancel_outcome == "ended":
            self.disconnected.append(room_key)
            self.alive.discard(room_key)
        return self.cancel_outcome

    def has_bot(self, room_key):
        return room_key in self.alive

    async def wait_joined(self, room_key, timeout):
        self.waits.append((room_key, timeout))
        if self.on_wait is not None:
            await self.on_wait(room_key)
        if self.join_outcome == "timeout":
            await asyncio.sleep(timeout)
        return self.join_outcome

    async def dispatch(
        self, *, room_key, agent_id, transport, bot_argv, cleanup=None, control=False,
        report_joined=False, bot_env=None,
    ):
        self.calls.append((room_key, agent_id, transport, tuple(bot_argv)))
        self.envs.append(bot_env)
        self.controls.append(control)
        self.reports_joined.append(report_joined)
        self.alive.add(room_key)
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

        # The bot was dispatched into the room with the BOT token (not the app
        # token), through its environment: argv is visible to every user in `ps`.
        calls = app.state.dispatcher.calls
        assert len(calls) == 1
        room_key, agent_id, transport, argv = calls[0]
        assert (room_key, agent_id, transport) == ("room-abc", "loopback", "daily")
        assert "--room-url" in argv
        assert "token-bot" not in argv
        assert argv[argv.index("--token-env") + 1] == "CONDUIT_BOT_TOKEN"
        assert app.state.dispatcher.envs == [{"CONDUIT_BOT_TOKEN": "token-bot"}]
        # The request listed no call signals: the bot greets when the client is ready.
        assert "--await-connected" not in argv


def test_connect_for_a_client_that_sends_call_connected_starts_an_awaiting_bot():
    for transport in ("daily", "livekit"):
        with TestClient(app) as c:
            app.state.daily = FakeDaily()
            app.state.livekit = FakeLiveKit()
            app.state.dispatcher = FakeDispatcher()
            r = c.post(
                "/connect/loopback",
                json={"transport": transport, "call_signals": ["call-connected", "call-held", "call-resumed"]},
                headers=AUTH,
            )
            assert r.status_code == 200, r.text
            ((_, _, _, argv),) = app.state.dispatcher.calls
            assert "--await-connected" in argv, transport
            # An outgoing call: no ring flags.
            assert "--ring-deadline" not in argv and "--joins-before-answer" not in argv


def test_connect_ignores_signals_it_does_not_know_and_rejects_malformed_ones():
    with TestClient(app) as c:
        app.state.daily = FakeDaily()
        app.state.dispatcher = FakeDispatcher()
        r = c.post("/connect/loopback", json={"transport": "daily", "call_signals": ["call-teleported"]}, headers=AUTH)
        assert r.status_code == 200, r.text
        ((_, _, _, argv),) = app.state.dispatcher.calls
        assert "--await-connected" not in argv
        for bad in ("call-connected", [1], [""], ["x" * 65], ["s"] * 33):
            r = c.post("/connect/loopback", json={"transport": "daily", "call_signals": bad}, headers=AUTH)
            assert r.status_code == 422, (bad, r.text)


def test_credentials_direct_registers_room_without_dispatch():
    # The lifespan builds a fresh :memory: registry per TestClient context.
    with TestClient(app) as c:
        app.state.daily = FakeDaily()
        app.state.dispatcher = FakeDispatcher()

        r = c.post("/credentials", json={"agent_id": "live", "transport": "daily"}, headers=AUTH)
        assert r.status_code == 200, r.text

        # No dispatch at provision time (that happens later via webhook).
        assert app.state.dispatcher.calls == []
        # Room is registered for the webhook to find, with its URL stored.
        rec = app.state.registry._get_room("room-abc")
        assert rec is not None
        assert rec.agent_id == "live"
        assert rec.room_url == "https://x.daily.co/room-abc"


def test_livekit_pairing_returns_room_url_shape():
    # The app reads `room_url` (docs/CONNECTION_CONTRACT.md); `url` is the alias.
    with TestClient(app) as c:
        app.state.livekit = FakeLiveKit()
        app.state.dispatcher = FakeDispatcher()

        r = c.post("/connect", json={"transport": "livekit"}, headers=AUTH)
        assert r.status_code == 200, r.text
        body = r.json()
        conn = body["connection"]
        assert conn["room_url"] == "wss://example.livekit.cloud"
        assert conn["url"] == conn["room_url"]
        assert conn["token"] == "lk-token-app"
        assert conn["room_name"].startswith("conduit-")

        # The bot got the agent token, joined to the same room.
        ((room_key, agent_id, transport, argv),) = app.state.dispatcher.calls
        assert (room_key, transport) == (conn["room_name"], "livekit")
        assert "lk-token-bot" not in argv and "--token-env" in argv
        assert app.state.dispatcher.envs == [{"CONDUIT_BOT_TOKEN": "lk-token-bot"}]


def test_connect_default_agent_is_loopback():
    with TestClient(app) as c:
        app.state.daily = FakeDaily()
        app.state.dispatcher = FakeDispatcher()

        r = c.post("/connect", json={"transport": "daily"}, headers=AUTH)
        assert r.status_code == 200, r.text
        assert r.json()["agent_id"] == "loopback"


def test_connect_path_route_identifies_agent():
    # The Conduit app POSTs {"transport": ...} with no agent_id — the URL is the agent.
    with TestClient(app) as c:
        app.state.daily = FakeDaily()
        app.state.dispatcher = FakeDispatcher()

        r = c.post("/connect/loopback", json={"transport": "daily"}, headers=AUTH)
        assert r.status_code == 200, r.text
        assert r.json()["agent_id"] == "loopback"
        ((_, agent_id, _, _),) = app.state.dispatcher.calls
        assert agent_id == "loopback"


def test_path_agent_overrides_body_agent():
    with TestClient(app) as c:
        app.state.daily = FakeDaily()
        app.state.dispatcher = FakeDispatcher()

        r = c.post(
            "/connect/loopback",
            json={"agent_id": "live", "transport": "daily"},
            headers=AUTH,
        )
        assert r.status_code == 200, r.text
        assert r.json()["agent_id"] == "loopback"


def test_connect_path_route_unknown_agent_404s():
    with TestClient(app) as c:
        app.state.daily = FakeDaily()
        app.state.dispatcher = FakeDispatcher()

        r = c.post("/connect/nonexistent", json={"transport": "daily"}, headers=AUTH)
        assert r.status_code == 404, r.text
        assert app.state.dispatcher.calls == []


def test_credentials_path_route_registers_without_dispatch():
    with TestClient(app) as c:
        app.state.daily = FakeDaily()
        app.state.dispatcher = FakeDispatcher()

        # No body at all — the path names the agent, defaults cover the rest.
        r = c.post("/credentials/loopback", headers=AUTH)
        assert r.status_code == 200, r.text
        assert r.json()["agent_id"] == "loopback"
        assert app.state.dispatcher.calls == []
        rec = app.state.registry._get_room("room-abc")
        assert rec is not None and rec.agent_id == "loopback"


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
