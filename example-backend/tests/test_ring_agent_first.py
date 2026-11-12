"""The pre-connect tier a ring asks for by default: the best the device's
registration takes, "none" to opt out. APNs, Daily, LiveKit and the dispatcher
are faked; no network."""

from fastapi.testclient import TestClient

from app.main import app

from test_connect_flow import FakeDaily, FakeDispatcher, FakeLiveKit
from test_inbound import APP_UUID, AUTH, REGISTER_BODY, FakeApns
from test_ring_lifecycle import ALL_FEATURES, CALL_SIGNALS, FEATURED_BODY

# preconnect + call-connected: "media". preconnect only: "credentials". Neither: none.
CREDS_BODY = {**REGISTER_BODY, "push_features": ALL_FEATURES}
STATUS_URL = "http://testserver/inbound/status/loopback"
PREPARED_CONNECTION = {"room_url": "https://x.daily.co/room-abc", "token": "token-app"}


def _setup(c, body=FEATURED_BODY):
    app.state.daily = FakeDaily()
    app.state.livekit = FakeLiveKit()
    app.state.dispatcher = FakeDispatcher()
    app.state.apns = FakeApns()
    assert c.post("/inbound/register/loopback", json=body, headers=AUTH).status_code == 200


def _ring(c, **body):
    r = c.post("/admin/ring/loopback", json=body, headers=AUTH)
    assert r.status_code == 200, r.text
    return r.json()


def _pushed():
    return app.state.apns.sends[-1][2]


def _argv(i=-1):
    return list(app.state.dispatcher.calls[i][3])


# --- the default pre-connect tier ---


def test_a_ring_asks_for_the_best_preconnect_the_registration_takes():
    for body, tier in ((FEATURED_BODY, "media"), (CREDS_BODY, "credentials")):
        for inline in (False, True):
            with TestClient(app) as c:
                _setup(c, body)
                r = _ring(c, inline=inline)
                assert r["preconnect"] == tier, (tier, inline)
                assert _pushed()["preconnect"] == tier
                assert app.state.rings.get(r["call_id"]).preconnect == tier
                if inline:
                    argv = _argv()
                    assert "--ring-deadline" in argv
                    assert ("--joins-before-answer" in argv) == (tier == "media")
                    assert ("--await-connected" in argv) == (tier == "media")


def test_a_registration_without_preconnect_gets_todays_plain_ring():
    for features in ([], ["cancel", "ring_timeout"]):
        body = {**REGISTER_BODY, "push_features": features, "call_signals": CALL_SIGNALS}
        with TestClient(app) as c:
            _setup(c, body)
            r = _ring(c)
            # Byte for byte the push a ring sent before pre-connect existed.
            assert _pushed() == {"agent_id": APP_UUID, "call_id": r["call_id"], "status_url": STATUS_URL}
            assert r["preconnect"] is None
            assert app.state.dispatcher.calls == []

            r = _ring(c, inline=True)
            assert _pushed() == {
                "agent_id": APP_UUID, "call_id": r["call_id"], "status_url": STATUS_URL,
                **PREPARED_CONNECTION,
            }
            assert r["preconnect"] is None
            argv = _argv()
            assert "--ring-deadline" not in argv and "--joins-before-answer" not in argv
            assert app.state.dispatcher.controls == [False]


def test_preconnect_none_opts_out_for_a_registration_that_takes_media():
    with TestClient(app) as c:
        _setup(c)
        r = _ring(c, preconnect="none")
        assert _pushed() == {"agent_id": APP_UUID, "call_id": r["call_id"], "status_url": STATUS_URL}
        assert r["preconnect"] is None
        assert app.state.rings.get(r["call_id"]).preconnect is None

        r = _ring(c, inline=True, preconnect="none")
        assert set(_pushed()) == {"agent_id", "call_id", "status_url", "room_url", "token"}
        assert r["preconnect"] is None
        argv = _argv()
        assert "--ring-deadline" not in argv and "--joins-before-answer" not in argv
        assert "--await-connected" in argv
        assert app.state.dispatcher.controls == [False]


def test_explicit_tiers_are_still_honoured():
    with TestClient(app) as c:
        _setup(c)
        for inline in (False, True):
            r = _ring(c, inline=inline, preconnect="credentials")
            assert r["preconnect"] == _pushed()["preconnect"] == "credentials"
            if inline:
                assert "--joins-before-answer" not in _argv()
            r = _ring(c, inline=inline, preconnect="media")
            assert r["preconnect"] == _pushed()["preconnect"] == "media"
            if inline:
                assert "--joins-before-answer" in _argv()
    with TestClient(app) as c:
        _setup(c, CREDS_BODY)
        r = _ring(c, preconnect="media")
        assert r["preconnect"] == _pushed()["preconnect"] == "credentials"
