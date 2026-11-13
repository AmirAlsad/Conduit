"""SmallWebRTC: the /connect pairing contract, the offer route's dual-bearer
auth, the ephemeral token store, and the immediate-end presence policy. The
pipecat handler itself is faked — no aiortc negotiation runs here."""

import time

from fastapi.testclient import TestClient

from app.config import settings
from app.main import app
from app.obs import get_logger
from app.transports.smallwebrtc import SmallWebRTCService
from bot.call_control import CallControl
from bot.runtime import _wire_presence
from tests.test_teardown import FakeEventTransport, FakeWorker
from bot.teardown import TeardownController

AUTH = {"Authorization": f"Bearer {settings.engine_api_key}"}

OFFER_BODY = {"sdp": "v=0...", "type": "offer"}


class FakeSmallWebRTC:
    """Stands in for SmallWebRTCService on app.state: real token semantics are
    unit-tested below; routes only need validate/handle recording."""

    def __init__(self, valid_token=None, valid_agent=None, awaiting_token=None):
        self.valid = (valid_token, valid_agent)
        self.awaiting_token = awaiting_token
        self.minted = []
        self.offers = []
        self.awaits = []
        self.patches = []

    def mint_token(self, agent_id, ttl_secs, *, await_connected=False):
        self.minted.append((agent_id, await_connected))
        return "minted-token"

    def validate_token(self, presented, agent_id):
        return (presented, agent_id) == self.valid

    def awaits_connected(self, presented):
        return presented == self.awaiting_token

    async def handle_offer(self, agent_id, payload, *, await_connected=False):
        self.offers.append((agent_id, payload))
        self.awaits.append(await_connected)
        return {"sdp": "v=0...answer", "type": "answer", "pc_id": "pc-1"}

    async def handle_patch(self, payload):
        self.patches.append(payload)

    async def close(self):
        pass


class FakeDispatcher:
    def __init__(self):
        self.calls = []

    async def dispatch(self, **kwargs):
        self.calls.append(kwargs)
        return 12345


# --- pairing contract through /connect ---


def test_connect_pairing_smallwebrtc_contract_and_no_dispatch():
    with TestClient(app) as c:
        fake = FakeSmallWebRTC()
        app.state.smallwebrtc = fake
        app.state.dispatcher = FakeDispatcher()

        r = c.post(
            "/connect/loopback", json={"transport": "smallwebrtc"}, headers=AUTH
        )
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["transport"] == "smallwebrtc"
        assert body["agent_id"] == "loopback"
        # Offer URL derived from the address the request arrived on (LAN case).
        assert body["connection"] == {
            "room_url": "http://testserver/webrtc/loopback/offer",
            "token": "minted-token",
        }
        assert body["expires_at"] is not None
        assert app.state.dispatcher.calls == []  # bot spawns on the offer, not here
        assert fake.minted == [("loopback", False)]  # a client that listed no signals


def test_connect_pairing_smallwebrtc_remembers_that_the_client_sends_call_connected():
    with TestClient(app) as c:
        fake = FakeSmallWebRTC()
        app.state.smallwebrtc = fake
        r = c.post(
            "/connect/loopback",
            json={"transport": "smallwebrtc", "call_signals": ["call-connected", "call-held"]},
            headers=AUTH,
        )
        assert r.status_code == 200, r.text
        assert fake.minted == [("loopback", True)]


def test_connect_pairing_smallwebrtc_uses_the_address_the_phone_reached(monkeypatch):
    # PUBLIC_BASE_URL is the scripts' default (often a deployed host); a phone
    # pairing over the LAN must get an offer URL on the LAN address it used.
    monkeypatch.setattr(settings, "public_base_url", "https://engine.example.com")
    with TestClient(app, base_url="http://192.168.1.50:8000") as c:
        app.state.smallwebrtc = FakeSmallWebRTC()
        r = c.post(
            "/connect/loopback", json={"transport": "smallwebrtc"}, headers=AUTH
        )
        assert r.status_code == 200, r.text
        room_url = r.json()["connection"]["room_url"]
        assert room_url == "http://192.168.1.50:8000/webrtc/loopback/offer"


def _register_smallwebrtc(c, **extra):
    body = {
        "voip_token": "ab12cd34",
        "bundle_id": "com.example.Conduit",
        "agent_id": "7b1bbe22-93b8-4a5e-9e2f-0c1a2b3c4d5e",
        "transport": "smallwebrtc",
        **extra,
    }
    assert c.post("/inbound/register/loopback", json=body, headers=AUTH).status_code == 200


def test_an_inline_smallwebrtc_ring_pushes_an_offer_url_on_the_rings_address(monkeypatch):
    from test_inbound import FakeApns

    monkeypatch.setattr(settings, "public_base_url", "")
    with TestClient(app, base_url="http://192.168.1.50:8000") as c:
        app.state.smallwebrtc = FakeSmallWebRTC()
        app.state.apns = FakeApns()
        _register_smallwebrtc(c)
        r = c.post("/admin/ring/loopback", json={"inline": True}, headers=AUTH)
        assert r.status_code == 200, r.text
        ((_, _, payload),) = app.state.apns.sends
        # The same address the push's status_url uses.
        assert payload["room_url"] == "http://192.168.1.50:8000/webrtc/loopback/offer"
        assert payload["status_url"].startswith("http://192.168.1.50:8000/")
        assert payload["token"] == "minted-token"


def test_credentials_smallwebrtc_is_pairing_only():
    with TestClient(app) as c:
        r = c.post(
            "/credentials/loopback", json={"transport": "smallwebrtc"}, headers=AUTH
        )
        assert r.status_code == 503
        assert "pairing-only" in r.json()["detail"]


# --- offer route auth matrix ---


def test_offer_rejects_missing_and_wrong_bearer():
    with TestClient(app) as c:
        app.state.smallwebrtc = FakeSmallWebRTC()
        assert c.post("/webrtc/loopback/offer", json=OFFER_BODY).status_code == 401
        r = c.post(
            "/webrtc/loopback/offer",
            json=OFFER_BODY,
            headers={"Authorization": "Bearer wrong"},
        )
        assert r.status_code == 401


def test_offer_accepts_engine_key():
    with TestClient(app) as c:
        fake = FakeSmallWebRTC()
        app.state.smallwebrtc = fake
        r = c.post("/webrtc/loopback/offer", json=OFFER_BODY, headers=AUTH)
        assert r.status_code == 200, r.text
        assert r.json()["type"] == "answer"
        agent_id, payload = fake.offers[0]
        assert agent_id == "loopback"
        assert payload["sdp"] == "v=0..."
        assert fake.awaits == [False]  # the engine key carries no pairing request


def test_an_offer_on_a_token_whose_pairing_listed_call_connected_starts_an_awaiting_bot():
    with TestClient(app) as c:
        fake = FakeSmallWebRTC(
            valid_token="minted-token", valid_agent="loopback", awaiting_token="minted-token"
        )
        app.state.smallwebrtc = fake
        r = c.post(
            "/webrtc/loopback/offer",
            json=OFFER_BODY,
            headers={"Authorization": "Bearer minted-token"},
        )
        assert r.status_code == 200, r.text
        assert fake.awaits == [True]


def test_offer_accepts_minted_token_for_matching_agent_only():
    with TestClient(app) as c:
        app.state.smallwebrtc = FakeSmallWebRTC(
            valid_token="ephemeral-1", valid_agent="loopback"
        )
        ok = c.post(
            "/webrtc/loopback/offer",
            json=OFFER_BODY,
            headers={"Authorization": "Bearer ephemeral-1"},
        )
        assert ok.status_code == 200, ok.text
        cross = c.post(
            "/webrtc/live/offer",
            json=OFFER_BODY,
            headers={"Authorization": "Bearer ephemeral-1"},
        )
        assert cross.status_code == 401


def test_offer_unknown_agent_404s():
    with TestClient(app) as c:
        app.state.smallwebrtc = FakeSmallWebRTC()
        r = c.post("/webrtc/nope/offer", json=OFFER_BODY, headers=AUTH)
        assert r.status_code == 404


def test_patch_routes_candidates():
    with TestClient(app) as c:
        fake = FakeSmallWebRTC()
        app.state.smallwebrtc = fake
        body = {
            "pc_id": "pc-1",
            "candidates": [
                {"candidate": "candidate:1 1 udp ...", "sdp_mid": "0", "sdp_mline_index": 0}
            ],
        }
        r = c.patch("/webrtc/loopback/offer", json=body, headers=AUTH)
        assert r.status_code == 200, r.text
        assert fake.patches == [body]


# --- ephemeral token store ---


def test_token_store_mint_validate_and_cross_agent():
    svc = SmallWebRTCService()
    token = svc.mint_token("loopback", ttl_secs=300)
    assert svc.validate_token(token, "loopback")
    assert not svc.validate_token(token, "live")
    assert not svc.validate_token("forged", "loopback")


def test_token_store_remembers_whether_the_client_sends_call_connected():
    svc = SmallWebRTCService()
    awaiting = svc.mint_token("loopback", ttl_secs=300, await_connected=True)
    plain = svc.mint_token("loopback", ttl_secs=300)
    assert svc.awaits_connected(awaiting)
    assert not svc.awaits_connected(plain)
    assert not svc.awaits_connected("forged")
    assert not svc.awaits_connected(settings.engine_api_key)


def test_token_store_expiry(monkeypatch):
    svc = SmallWebRTCService()
    token = svc.mint_token("loopback", ttl_secs=300)
    far_future = time.time() + 301
    monkeypatch.setattr(time, "time", lambda: far_future)
    assert not svc.validate_token(token, "loopback")


# --- presence policy: a dropped peer ends the bot immediately, no grace ---


async def test_client_disconnect_ends_immediately():
    log = get_logger("test")
    worker = FakeWorker()
    controller = TeardownController(worker, grace_secs=100, log=log)
    transport = FakeEventTransport()
    call = CallControl(teardown=controller, greet=None, log=log)
    _wire_presence(transport, "smallwebrtc", controller, call, log)
    controller.human_joined("pc-1")
    await transport.handlers["on_client_disconnected"](transport, object())
    assert worker.cancelled == 1
