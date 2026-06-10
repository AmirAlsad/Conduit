"""Inbound calls: token registration + /admin/ring, with APNs faked (no network).
Locks in the push payload contract (docs/INBOUND_CALLS.md §2) and the eviction
behavior on APNs 410."""

import uuid

from fastapi.testclient import TestClient

from app.apns import ApnsResult
from app.config import settings
from app.main import app

from test_connect_flow import FakeDaily, FakeDispatcher

AUTH = {"Authorization": f"Bearer {settings.engine_api_key}"}
APP_UUID = "7b1bbe22-93b8-4a5e-9e2f-0c1a2b3c4d5e"

REGISTER_BODY = {
    "voip_token": "ab12cd34",
    "platform": "ios",
    "bundle_id": "com.example.Conduit",
    "agent_id": APP_UUID,
}


class FakeApns:
    def __init__(self, result: ApnsResult | None = None):
        self.result = result or ApnsResult(status=200, apns_id="apns-1")
        self.sends = []

    async def send_voip_push(self, *, voip_token, bundle_id, payload):
        self.sends.append((voip_token, bundle_id, payload))
        return self.result


def _register(c, agent="loopback"):
    r = c.post(f"/inbound/register/{agent}", json=REGISTER_BODY, headers=AUTH)
    assert r.status_code == 200, r.text


def test_register_stores_token():
    with TestClient(app) as c:
        _register(c)
        stored = app.state.registry._get_voip("loopback")
        assert stored is not None
        assert stored.voip_token == "ab12cd34"
        assert stored.app_agent_id == APP_UUID
        assert stored.bundle_id == "com.example.Conduit"


def test_register_unknown_agent_404s():
    with TestClient(app) as c:
        r = c.post("/inbound/register/nonexistent", json=REGISTER_BODY, headers=AUTH)
        assert r.status_code == 404, r.text


def test_register_and_ring_require_bearer():
    with TestClient(app) as c:
        assert c.post("/inbound/register/loopback", json=REGISTER_BODY).status_code in (401, 403)
        assert c.post("/admin/ring/loopback").status_code in (401, 403)


def test_ring_pairing_mode_sends_credential_free_push():
    with TestClient(app) as c:
        app.state.daily = FakeDaily()
        app.state.dispatcher = FakeDispatcher()
        app.state.apns = FakeApns()
        _register(c)

        r = c.post("/admin/ring/loopback", headers=AUTH)
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["mode"] == "pairing"
        assert body["agent_id"] == APP_UUID

        ((token, bundle_id, payload),) = app.state.apns.sends
        assert (token, bundle_id) == ("ab12cd34", "com.example.Conduit")
        assert payload["agent_id"] == APP_UUID
        uuid.UUID(payload["call_id"])  # parseable
        assert payload["status_url"].endswith("/inbound/status/loopback")
        assert "room_url" not in payload and "token" not in payload
        # Nothing provisioned or billed until the user answers and the app pairs.
        assert app.state.dispatcher.calls == []


def test_ring_inline_mode_provisions_and_embeds_creds():
    with TestClient(app) as c:
        app.state.daily = FakeDaily()
        app.state.dispatcher = FakeDispatcher()
        app.state.apns = FakeApns()
        _register(c)

        r = c.post("/admin/ring/loopback", json={"inline": True}, headers=AUTH)
        assert r.status_code == 200, r.text
        assert r.json()["mode"] == "inline"

        ((_, _, payload),) = app.state.apns.sends
        assert payload["room_url"] == "https://x.daily.co/room-abc"
        assert payload["token"] == "token-app"
        # Inline dispatches the bot before the user answers — exactly once.
        assert len(app.state.dispatcher.calls) == 1


def test_ring_without_registration_404s():
    with TestClient(app) as c:
        app.state.apns = FakeApns()
        r = c.post("/admin/ring/loopback", headers=AUTH)
        assert r.status_code == 404, r.text
        assert app.state.apns.sends == []


def test_ring_apns_410_evicts_registration():
    with TestClient(app) as c:
        app.state.apns = FakeApns(ApnsResult(status=410, reason="Unregistered"))
        _register(c)

        r = c.post("/admin/ring/loopback", headers=AUTH)
        assert r.status_code == 502, r.text
        assert r.json()["detail"]["reason"] == "Unregistered"
        # The stale token was evicted; the next ring is a clean 404.
        assert app.state.registry._get_voip("loopback") is None


def test_ring_apns_bad_token_surfaces_reason_and_hint():
    with TestClient(app) as c:
        app.state.apns = FakeApns(ApnsResult(status=400, reason="BadDeviceToken"))
        _register(c)

        r = c.post("/admin/ring/loopback", headers=AUTH)
        assert r.status_code == 502, r.text
        detail = r.json()["detail"]
        assert detail["reason"] == "BadDeviceToken"
        assert "APNS_USE_SANDBOX" in detail["hint"]
        # Only 410 evicts; a sandbox/prod mismatch keeps the registration.
        assert app.state.registry._get_voip("loopback") is not None


def test_ring_without_apns_config_503s():
    # The real sender validates its settings at point of use (none are set in tests).
    with TestClient(app) as c:
        _register(c)
        r = c.post("/admin/ring/loopback", headers=AUTH)
        assert r.status_code == 503, r.text
        assert "apns" in r.json()["detail"].lower()


def test_ring_status_receipt_accepted():
    with TestClient(app) as c:
        body = {"call_id": str(uuid.uuid4()), "status": "suppressed_by_focus"}
        r = c.post("/inbound/status/loopback", json=body, headers=AUTH)
        assert r.status_code == 200, r.text
        assert r.json() == {"ok": True}


def test_ring_status_rejects_unknown_agent_and_bad_status():
    with TestClient(app) as c:
        body = {"call_id": str(uuid.uuid4()), "status": "answered"}
        assert c.post("/inbound/status/nonexistent", json=body, headers=AUTH).status_code == 404
        bad = {"call_id": str(uuid.uuid4()), "status": "exploded"}
        assert c.post("/inbound/status/loopback", json=bad, headers=AUTH).status_code == 422
        assert c.post("/inbound/status/loopback", json=body).status_code in (401, 403)
