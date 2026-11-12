"""Ring lifecycle on the engine: ring_timeout / preconnect push keys, ring bots
(deadline + await-answer flags), receipts steering them, and the cancel
endpoint (docs/INBOUND_CALLS.md). APNs, Daily, LiveKit and the dispatcher are
faked; no network."""

import uuid

from fastapi.testclient import TestClient

from app.apns import ApnsResult
from app.config import settings
from app.main import app
from app.rings import CANCEL_UNSUPPORTED, RingTracker, TrackedRing, ring_deadline_secs

from test_connect_flow import FakeDaily, FakeDispatcher, FakeLiveKit
from test_inbound import AUTH, FEATURES, NAMED_BODY, REGISTER_BODY, FakeApns

_BASE_KEYS = {"agent_id", "call_id", "status_url"}
# An app on call engine 0.2+, which lists the push features; REGISTER_BODY is
# an older app, which lists none.
ALL_FEATURES = [*FEATURES, "preconnect"]
FEATURED_BODY = {**REGISTER_BODY, "push_features": ALL_FEATURES}
# Takes a pre-connected ring but no cancel push.
NO_CANCEL_BODY = {**REGISTER_BODY, "push_features": ["preconnect"]}


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


def _setup(c, body=FEATURED_BODY, daily=None, livekit=None):
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


def test_ring_timeout_is_left_out_for_a_device_without_the_feature():
    for body in (REGISTER_BODY, {**REGISTER_BODY, "push_features": ["cancel"]}):
        with TestClient(app) as c:
            _setup(c, body=body)
            r = c.post("/admin/ring/loopback", json={"ring_timeout": 30}, headers=AUTH)
            assert r.status_code == 200, r.text
            assert r.json()["ring_timeout"] is None
            payload = app.state.apns.sends[-1][2]
            assert set(payload) == _BASE_KEYS
            assert app.state.rings.get(payload["call_id"]).ring_timeout is None


def test_ring_response_reports_the_ring_timeout_sent():
    with TestClient(app) as c:
        _setup(c)
        r = c.post("/admin/ring/loopback", json={"ring_timeout": 30}, headers=AUTH)
        assert r.json()["ring_timeout"] == 30
        r = c.post("/admin/ring/loopback", json={}, headers=AUTH)
        assert r.json()["ring_timeout"] is None


# Lists preconnect (and cancel) but not ring_timeout.
NO_TIMEOUT_BODY = {**REGISTER_BODY, "push_features": ["cancel", "preconnect"]}


def test_ring_bot_deadline_assumes_the_default_when_ring_timeout_is_not_sent():
    # The device rings for its own default, so the bot must not give up at 30 s.
    with TestClient(app) as c:
        _setup(c, body=NO_TIMEOUT_BODY)
        _, payload = _ring(c, inline=True, preconnect="credentials", ring_timeout=30)
        assert "ring_timeout" not in payload
        assert _deadline(_argv()) == settings.ring_timeout_secs + settings.ring_deadline_margin_secs


def test_pairing_ring_bot_deadline_assumes_the_default_when_ring_timeout_is_not_sent():
    with TestClient(app) as c:
        _setup(c, body=NO_TIMEOUT_BODY)
        call_id, _ = _ring(c, preconnect="media", ring_timeout=20)
        r = c.post(
            "/connect/loopback",
            json={"transport": "daily", "ring": {"call_id": call_id, "await_answer": True}},
            headers=AUTH,
        )
        assert r.status_code == 200, r.text
        assert _deadline(_argv()) == settings.ring_timeout_secs + settings.ring_deadline_margin_secs


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


def test_preconnect_is_left_out_for_a_device_without_the_feature():
    # An older app would answer an inline media ring into a bot whose audio is
    # closed and that waits for a call-answered the app never sends.
    for features in ([], ["cancel", "ring_timeout"]):
        body = {**REGISTER_BODY, "push_features": features}
        for kwargs in ({}, {"inline": True}):
            with TestClient(app) as c:
                _setup(c, body=body)
                r = c.post(
                    "/admin/ring/loopback",
                    json={**kwargs, "preconnect": "media"},
                    headers=AUTH,
                )
                assert r.status_code == 200, r.text
                assert r.json()["preconnect"] is None
                payload = app.state.apns.sends[-1][2]
                assert "preconnect" not in payload
                ring = app.state.rings.get(payload["call_id"])
                assert ring.preconnect is None and not ring.ring_bot and not ring.awaits_answer
                if kwargs:
                    # Dispatched exactly like a plain inline ring.
                    assert "--await-answer" not in _argv()
                    assert "--ring-deadline" not in _argv()
                    assert app.state.dispatcher.controls == [False]
                else:
                    assert app.state.dispatcher.calls == []


def test_ring_response_reports_the_preconnect_sent():
    with TestClient(app) as c:
        _setup(c)
        r = c.post("/admin/ring/loopback", json={"preconnect": "credentials"}, headers=AUTH)
        assert r.json()["preconnect"] == "credentials"
        r = c.post("/admin/ring/loopback", json={}, headers=AUTH)
        assert r.json()["preconnect"] is None


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


def test_connect_with_an_uppercase_ring_id_attaches_to_the_tracked_ring():
    # The app's engine formats call ids with Swift's uuidString (uppercase).
    with TestClient(app) as c:
        _setup(c)
        call_id, _ = _ring(c, preconnect="credentials", ring_timeout=20)
        r = c.post(
            "/connect/loopback",
            json={"transport": "daily", "ring": {"call_id": call_id.upper(), "await_answer": False}},
            headers=AUTH,
        )
        assert r.status_code == 200, r.text
        assert _deadline(_argv()) == 20 + settings.ring_deadline_margin_secs
        assert app.state.rings.get(call_id).ring_bot


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


def test_receipts_match_their_ring_whatever_the_ids_case():
    with TestClient(app) as c:
        _setup(c)
        call_id, _ = _ring(c, inline=True, preconnect="media")
        _receipt(c, call_id.upper(), "answered")
        assert app.state.dispatcher.sent == [("room-abc", "answered")]
        assert app.state.rings.get(call_id).status == "answered"

        call_id, _ = _ring(c, inline=True, preconnect="credentials")
        _receipt(c, call_id.upper(), "declined")
        assert app.state.dispatcher.disconnected == ["room-abc"]


def test_non_answered_receipts_end_the_ring_bot():
    for status in ("declined", "busy", "suppressed_by_focus", "unanswered", "canceled", "exploded"):
        with TestClient(app) as c:
            _setup(c)
            call_id, _ = _ring(c, inline=True, preconnect="credentials")
            _receipt(c, call_id, status)
            assert app.state.dispatcher.disconnected == ["room-abc"], status


def test_non_answered_receipts_end_a_plain_inline_bot():
    for status in ("declined", "busy", "suppressed_by_focus", "unanswered", "canceled", "exploded"):
        with TestClient(app) as c:
            _setup(c)
            call_id, _ = _ring(c, inline=True)
            _receipt(c, call_id, status)
            assert app.state.dispatcher.disconnected == ["room-abc"], status
            # It has no control pipe to write to.
            assert app.state.dispatcher.sent == [], status
            assert app.state.rings.get(call_id).status == status


def test_answered_receipt_leaves_a_plain_inline_bot_running():
    with TestClient(app) as c:
        _setup(c)
        call_id, _ = _ring(c, inline=True)
        _receipt(c, call_id, "answered")
        assert app.state.dispatcher.disconnected == []
        assert app.state.dispatcher.sent == []
        # Only the first receipt counts: a stray decline can't end the answered call.
        _receipt(c, call_id, "declined")
        assert app.state.dispatcher.disconnected == []
        assert app.state.rings.get(call_id).status == "answered"


def test_only_the_first_receipt_ends_a_plain_inline_bot():
    with TestClient(app) as c:
        _setup(c)
        call_id, _ = _ring(c, inline=True)
        _receipt(c, call_id, "declined")
        _receipt(c, call_id, "answered")
        _receipt(c, call_id, "busy")
        assert app.state.dispatcher.disconnected == ["room-abc"]
        assert app.state.dispatcher.sent == []
        assert app.state.rings.get(call_id).status == "declined"


def test_receipts_for_a_pairing_ring_without_a_bot_end_nothing():
    with TestClient(app) as c:
        _setup(c)
        call_id, _ = _ring(c)
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
        _setup(c, body={**NAMED_BODY, "push_features": FEATURES})
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


def test_cancel_accepts_an_uppercase_id():
    with TestClient(app) as c:
        _setup(c)
        call_id, _ = _ring(c)
        r = _cancel(c, call_id.upper())
        assert r.status_code == 200, r.text
        assert r.json()["call_id"] == call_id


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


def test_cancel_without_the_feature_is_refused_and_leaves_the_ring_alone():
    for body in (REGISTER_BODY, {**REGISTER_BODY, "push_features": ["ring_timeout"]}):
        with TestClient(app) as c:
            _setup(c, body=body)
            call_id, _ = _ring(c, inline=True)
            r = _cancel(c, call_id)
            assert r.status_code == 409, r.text
            assert r.json()["detail"] == {
                "call_id": call_id, "status": None, "reason": CANCEL_UNSUPPORTED,
            }
            assert len(app.state.apns.sends) == 1  # only the ring, no cancel push
            # Nothing was withdrawn: the ring and its bot are untouched...
            assert app.state.dispatcher.disconnected == []
            ring = app.state.rings.get(call_id)
            assert ring.canceled is False and ring.status is None
            # ...so the ring's receipt still steers its bot.
            _receipt(c, call_id, "declined")
            assert app.state.dispatcher.disconnected == ["room-abc"]


def test_cancel_refusal_can_be_retried_after_the_app_upgrades():
    with TestClient(app) as c:
        _setup(c, body=REGISTER_BODY)
        call_id, _ = _ring(c)
        assert _cancel(c, call_id).status_code == 409
        r = c.post("/inbound/register/loopback", json=FEATURED_BODY, headers=AUTH)
        assert r.status_code == 200
        r = _cancel(c, call_id)
        assert r.status_code == 200, r.text
        assert r.json()["method"] == "push"
        assert app.state.apns.sends[-1][2] == {"action": "cancel", "call_id": call_id}


def test_cancel_in_band_needs_no_feature():
    for transport, kwargs in (
        ("daily", {"daily": PresenceDaily(present=True)}),
        ("livekit", {"livekit": PresenceLiveKit(present=True)}),
    ):
        with TestClient(app) as c:
            _setup(c, body=NO_CANCEL_BODY, **kwargs)
            call_id, _ = _ring(c, inline=True, preconnect="media", transport=transport)
            r = _cancel(c, call_id)
            assert r.status_code == 200, r.text
            assert r.json()["method"] == "in_band", transport
            assert r.json()["bot_ended"] is True
            ring = app.state.rings.get(call_id)
            assert app.state.dispatcher.disconnected == [ring.room_key]
            assert len(app.state.apns.sends) == 1
            assert ring.canceled is True


def test_cancel_pre_connected_ring_without_the_human_or_the_feature_is_refused():
    with TestClient(app) as c:
        daily = PresenceDaily(present=False)
        _setup(c, body=NO_CANCEL_BODY, daily=daily)
        call_id, _ = _ring(c, inline=True, preconnect="media")
        r = _cancel(c, call_id)
        assert r.status_code == 409, r.text
        assert r.json()["detail"]["reason"] == CANCEL_UNSUPPORTED
        assert daily.asked == ["room-abc"]
        assert app.state.dispatcher.disconnected == []
        assert len(app.state.apns.sends) == 1
        assert app.state.rings.get(call_id).canceled is False


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


def test_pairing_for_a_ring_before_apns_answers_is_kept():
    # The app can wake and pair while the engine still awaits APNs' response.
    with TestClient(app) as c:
        _setup(c)
        apns = app.state.apns
        connect_status = []

        async def slow_send(*, voip_token, bundle_id, payload):
            from httpx import ASGITransport, AsyncClient

            async with AsyncClient(transport=ASGITransport(app=app), base_url="http://t") as ac:
                r = await ac.post(
                    "/connect/loopback",
                    json={"transport": "daily", "ring": {"call_id": payload["call_id"], "await_answer": True}},
                    headers=AUTH,
                )
                connect_status.append(r.status_code)
            apns.sends.append((voip_token, bundle_id, payload))
            return ApnsResult(status=200, apns_id="x")

        apns.send_voip_push = slow_send
        call_id, _ = _ring(c, preconnect="media", ring_timeout=20)
        assert connect_status == [200]
        ring = app.state.rings.get(call_id)
        assert ring.room_key == "room-abc" and ring.preconnect == "media"
        assert _deadline(_argv()) == 20 + settings.ring_deadline_margin_secs


def test_failed_ring_push_is_not_tracked():
    with TestClient(app) as c:
        _setup(c)
        app.state.apns.result = ApnsResult(status=400, reason="BadDeviceToken")
        r = c.post("/admin/ring/loopback", json={}, headers=AUTH)
        assert r.status_code == 502
        call_id = app.state.apns.sends[-1][2]["call_id"]
        assert app.state.rings.get(call_id) is None
