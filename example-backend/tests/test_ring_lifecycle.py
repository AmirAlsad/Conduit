"""Ring lifecycle on the engine: ring_timeout / preconnect push keys, ring bots
(deadline + await-answer flags), receipts steering them, and the cancel
endpoint (docs/INBOUND_CALLS.md). APNs, Daily, LiveKit and the dispatcher are
faked; no network."""

import uuid

from fastapi.testclient import TestClient

from app.apns import ApnsResult
from app.config import settings
from app.main import app
from app.rings import RingTracker, TrackedRing, ring_deadline_secs

from test_connect_flow import FakeDaily, FakeDispatcher, FakeLiveKit
from test_inbound import AUTH, NAMED_BODY, REGISTER_BODY, FakeApns

_BASE_KEYS = {"agent_id", "call_id", "status_url"}


class PresenceDaily(FakeDaily):
    def __init__(self, present=True, error=False):
        self.present = present
        self.error = error
        self.asked = []

    async def human_in_room(self, room_name):
        self.asked.append(room_name)
        if self.error:
            raise RuntimeError("presence down")
        return self.present


class PresenceLiveKit(FakeLiveKit):
    def __init__(self, present=True):
        self.present = present

    async def human_in_room(self, room_name):
        return self.present


def _setup(c, body=REGISTER_BODY, daily=None, livekit=None):
    app.state.daily = daily or FakeDaily()
    app.state.livekit = livekit or FakeLiveKit()
    app.state.dispatcher = FakeDispatcher()
    app.state.apns = FakeApns()
    assert c.post("/inbound/register/loopback", json=body, headers=AUTH).status_code == 200


def _ring(c, **body):
    r = c.post("/admin/ring/loopback", json=body, headers=AUTH)
    assert r.status_code == 200, r.text
    return r.json()["call_id"], app.state.apns.sends[-1][2]


def _argv():
    ((_, _, _, argv),) = app.state.dispatcher.calls
    return list(argv)


def _deadline(argv):
    return float(argv[argv.index("--ring-deadline") + 1])


# --- the ring push ---


def test_ring_without_new_keys_sends_todays_payload():
    with TestClient(app) as c:
        _setup(c)
        _, payload = _ring(c)
        assert set(payload) == _BASE_KEYS
        _, payload = _ring(c, inline=True)
        assert set(payload) == _BASE_KEYS | {"room_url", "token"}
        # A plain inline bot is not a ring bot: no flags, no control pipe.
        argv = list(app.state.dispatcher.calls[-1][3])
        assert "--ring-deadline" not in argv and "--await-answer" not in argv
        assert app.state.dispatcher.controls == [False]


def test_ring_timeout_and_preconnect_ride_the_push_as_strings():
    with TestClient(app) as c:
        _setup(c)
        _, payload = _ring(c, ring_timeout=30, preconnect="media")
        assert payload["ring_timeout"] == "30"
        assert payload["preconnect"] == "media"
        assert "action" not in payload
        # Pairing mode: nothing is dispatched until the app pairs.
        assert app.state.dispatcher.calls == []


def test_ring_rejects_bad_new_keys():
    with TestClient(app) as c:
        _setup(c)
        for body in ({"ring_timeout": 0}, {"preconnect": "everything"}):
            r = c.post("/admin/ring/loopback", json=body, headers=AUTH)
            assert r.status_code == 422, r.text
        assert app.state.apns.sends == []


def test_inline_media_ring_dispatches_an_awaiting_ring_bot():
    with TestClient(app) as c:
        _setup(c)
        _ring(c, inline=True, preconnect="media")
        argv = _argv()
        assert "--await-answer" in argv
        assert _deadline(argv) == settings.ring_timeout_secs + settings.ring_deadline_margin_secs
        assert app.state.dispatcher.controls == [True]


def test_inline_credentials_ring_gets_a_deadline_but_does_not_await():
    with TestClient(app) as c:
        _setup(c)
        _ring(c, inline=True, preconnect="credentials", ring_timeout=30)
        argv = _argv()
        assert "--await-answer" not in argv
        assert _deadline(argv) == 30 + settings.ring_deadline_margin_secs


def test_ring_deadline_respects_the_apps_ten_second_floor():
    assert ring_deadline_secs(3) == 10 + settings.ring_deadline_margin_secs
    assert ring_deadline_secs(None) == settings.ring_timeout_secs + settings.ring_deadline_margin_secs


# --- pairing during the ring ---


def test_connect_with_ring_dispatches_a_ring_bot_and_tracks_it():
    with TestClient(app) as c:
        _setup(c)
        call_id, _ = _ring(c, preconnect="media", ring_timeout=20)
        r = c.post(
            "/connect/loopback",
            json={"transport": "daily", "ring": {"call_id": call_id, "await_answer": True}},
            headers=AUTH,
        )
        assert r.status_code == 200, r.text
        argv = _argv()
        assert "--await-answer" in argv
        assert _deadline(argv) == 20 + settings.ring_deadline_margin_secs
        ring = app.state.rings.get(call_id)
        assert (ring.room_key, ring.transport, ring.ring_bot, ring.awaits_answer) == (
            "room-abc", "daily", True, True,
        )


def test_connect_without_ring_is_unchanged():
    with TestClient(app) as c:
        _setup(c)
        assert c.post("/connect/loopback", json={"transport": "daily"}, headers=AUTH).status_code == 200
        assert "--ring-deadline" not in _argv()
        assert app.state.dispatcher.controls == [False]


def test_connect_with_ring_for_smallwebrtc_dispatches_nothing():
    with TestClient(app) as c:
        _setup(c)
        r = c.post(
            "/connect/loopback",
            json={"transport": "smallwebrtc", "ring": {"call_id": "abc"}},
            headers=AUTH,
        )
        assert r.status_code == 200, r.text
        assert app.state.dispatcher.calls == []
        assert app.state.rings.get("abc") is None


def test_tracker_adopts_unknown_rings_but_not_other_agents():
    rings = RingTracker()
    adopted = rings.attach_bot("c1", "live", room_key="r", transport="daily", awaits_answer=False)
    assert adopted is not None and adopted.mode == "pairing" and adopted.ring_bot
    rings.add(TrackedRing(call_id="c2", agent_id="loopback", mode="pairing"))
    assert rings.attach_bot("c2", "live", room_key="r", transport="daily", awaits_answer=False) is None


def test_tracker_forgets_rings_after_an_hour():
    now = [0.0]
    rings = RingTracker(clock=lambda: now[0])
    rings.add(TrackedRing(call_id="c1", agent_id="live", mode="pairing"))
    now[0] = 3601
    assert rings.get("c1") is None


# --- receipts ---


def _receipt(c, call_id, status):
    r = c.post(
        "/inbound/status/loopback", json={"call_id": call_id, "status": status}, headers=AUTH
    )
    assert r.status_code == 200, r.text


def test_answered_receipt_releases_the_ring_bot():
    with TestClient(app) as c:
        _setup(c)
        call_id, _ = _ring(c, inline=True, preconnect="media")
        _receipt(c, call_id, "answered")
        assert app.state.dispatcher.sent == [("room-abc", "answered")]
        assert app.state.dispatcher.disconnected == []
        # A stray second receipt must not end an answered call.
        _receipt(c, call_id, "declined")
        assert app.state.dispatcher.disconnected == []
        assert app.state.rings.get(call_id).status == "answered"


def test_non_answered_receipts_end_the_ring_bot():
    for status in ("declined", "busy", "suppressed_by_focus", "unanswered", "canceled", "exploded"):
        with TestClient(app) as c:
            _setup(c)
            call_id, _ = _ring(c, inline=True, preconnect="credentials")
            _receipt(c, call_id, status)
            assert app.state.dispatcher.disconnected == ["room-abc"], status


def test_receipts_leave_a_plain_inline_bot_alone():
    with TestClient(app) as c:
        _setup(c)
        call_id, _ = _ring(c, inline=True)
        _receipt(c, call_id, "declined")
        assert app.state.dispatcher.disconnected == []
        assert app.state.dispatcher.sent == []
        assert app.state.rings.get(call_id).status == "declined"


def test_receipt_for_another_agents_ring_is_only_logged():
    with TestClient(app) as c:
        _setup(c)
        call_id, _ = _ring(c, inline=True, preconnect="media")
        r = c.post(
            "/inbound/status/live", json={"call_id": call_id, "status": "declined"}, headers=AUTH
        )
        assert r.status_code == 200
        assert app.state.dispatcher.disconnected == []
        assert app.state.rings.get(call_id).status is None


# --- cancel ---


def _cancel(c, call_id, agent="loopback"):
    return c.post(f"/admin/ring/{agent}/cancel", json={"call_id": call_id}, headers=AUTH)


def test_cancel_push_omits_the_target_and_carries_the_name():
    with TestClient(app) as c:
        _setup(c, body=NAMED_BODY)
        call_id, _ = _ring(c)
        r = _cancel(c, call_id)
        assert r.status_code == 200, r.text
        assert r.json()["method"] == "push"
        assert r.json()["bot_ended"] is False
        payload = app.state.apns.sends[-1][2]
        assert payload == {"action": "cancel", "call_id": call_id, "display_name": "Ada"}


def test_cancel_unknown_ring_or_wrong_agent_404s():
    with TestClient(app) as c:
        _setup(c)
        assert _cancel(c, str(uuid.uuid4())).status_code == 404
        call_id, _ = _ring(c)
        assert _cancel(c, call_id, agent="live").status_code == 404
        assert len(app.state.apns.sends) == 1  # only the ring


def test_cancel_after_a_receipt_or_a_cancel_409s():
    with TestClient(app) as c:
        _setup(c)
        call_id, _ = _ring(c)
        _receipt(c, call_id, "declined")
        r = _cancel(c, call_id)
        assert r.status_code == 409, r.text
        assert r.json()["detail"]["status"] == "declined"

        call_id, _ = _ring(c)
        assert _cancel(c, call_id).status_code == 200
        assert _cancel(c, call_id).status_code == 409
        assert sum(1 for s in app.state.apns.sends if s[2].get("action") == "cancel") == 1


def test_cancel_pre_connected_ring_with_the_human_in_the_room_is_in_band():
    with TestClient(app) as c:
        daily = PresenceDaily(present=True)
        _setup(c, daily=daily)
        call_id, _ = _ring(c, inline=True, preconnect="media")
        r = _cancel(c, call_id)
        assert r.status_code == 200, r.text
        assert r.json() == {
            "call_id": call_id, "method": "in_band", "bot_ended": True,
            "apns_status": None, "apns_id": None,
        }
        assert daily.asked == ["room-abc"]
        assert app.state.dispatcher.disconnected == ["room-abc"]
        assert len(app.state.apns.sends) == 1  # no cancel push


def test_cancel_in_band_on_livekit_too():
    with TestClient(app) as c:
        _setup(c, livekit=PresenceLiveKit(present=True))
        call_id, _ = _ring(c, inline=True, preconnect="media", transport="livekit")
        assert _cancel(c, call_id).json()["method"] == "in_band"


def test_cancel_pre_connected_ring_without_the_human_pushes_and_ends_the_bot():
    for daily in (PresenceDaily(present=False), PresenceDaily(error=True)):
        with TestClient(app) as c:
            _setup(c, daily=daily)
            call_id, _ = _ring(c, inline=True, preconnect="media")
            r = _cancel(c, call_id)
            assert r.status_code == 200, r.text
            assert r.json()["method"] == "push"
            assert r.json()["bot_ended"] is True
            assert app.state.apns.sends[-1][2]["action"] == "cancel"
            assert app.state.dispatcher.disconnected == ["room-abc"]


def test_cancel_credentials_ring_never_checks_presence():
    with TestClient(app) as c:
        daily = PresenceDaily(present=True)
        _setup(c, daily=daily)
        call_id, _ = _ring(c, inline=True, preconnect="credentials")
        assert _cancel(c, call_id).json()["method"] == "push"
        assert daily.asked == []


def test_cancel_push_on_a_dead_token_502s_and_evicts():
    with TestClient(app) as c:
        _setup(c)
        call_id, _ = _ring(c)
        app.state.apns.result = ApnsResult(status=410, reason="Unregistered")
        r = _cancel(c, call_id)
        assert r.status_code == 502, r.text
        assert app.state.registry._get_voip("loopback") is None
        assert app.state.rings.get(call_id).canceled is False


# --- presence probes (what decides an in-band cancel) ---


class _Resp:
    def __init__(self, status, body):
        self.status = status
        self._body = body

    async def json(self):
        return self._body

    async def __aenter__(self):
        return self

    async def __aexit__(self, *exc):
        return False


class _Session:
    def __init__(self, resp):
        self.resp = resp
        self.urls = []

    def get(self, url, headers=None):
        self.urls.append(url)
        return self.resp


async def test_daily_presence_counts_anyone_but_the_bot():
    from app.transports.daily import DailyService

    bot = {"userName": settings.bot_name}
    session = _Session(_Resp(200, {"total_count": 1, "data": [bot]}))
    daily = DailyService(session)
    assert await daily.human_in_room("room-abc") is False
    assert session.urls == [f"{settings.daily_api_url}/rooms/room-abc/presence"]
    session.resp = _Resp(200, {"total_count": 2, "data": [bot, {"userName": "User"}]})
    assert await daily.human_in_room("room-abc") is True
    session.resp = _Resp(404, {})
    try:
        await daily.human_in_room("room-abc")
    except RuntimeError:
        pass
    else:
        raise AssertionError("a failed presence call must raise (the caller then pushes)")


async def test_livekit_presence_counts_anyone_but_the_bot(monkeypatch):
    from types import SimpleNamespace

    from app.transports import livekit as lk_module

    participants = [SimpleNamespace(name=settings.bot_name)]

    class FakeAPI:
        def __init__(self, *args):
            self.room = self

        async def __aenter__(self):
            return self

        async def __aexit__(self, *exc):
            return False

        async def list_participants(self, req):
            assert req.room == "conduit-1"
            return SimpleNamespace(participants=participants)

    monkeypatch.setattr(lk_module.api, "LiveKitAPI", FakeAPI)
    service = lk_module.LiveKitService()
    assert await service.human_in_room("conduit-1") is False
    participants.append(SimpleNamespace(name="User"))
    assert await service.human_in_room("conduit-1") is True
