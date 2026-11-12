"""Agent-first ringing: the pre-connect tier a ring asks for by default, the ring's
bot started before the push and the push sent once that bot has joined the room
(bounded by RING_BOT_WAIT_SECS), and a pre-connected pairing ring's room prepared
at ring time for the app's credential request. APNs, Daily, LiveKit and the
dispatcher are faked (the last also for real, over a fake subprocess); no network."""

import asyncio
import time

import pytest
from fastapi.testclient import TestClient
from httpx import ASGITransport, AsyncClient

from app.config import settings
from app.dispatch import Dispatcher
from app.main import app
from app.registry import SQLiteRegistry
from app.rings import CONTROL_JOINED, CONTROL_REPLY_PREFIX, RING_ENDED, RingTracker, ring_bot_flags, ring_deadline_secs
from app.routes import admin as admin_routes

from test_connect_flow import FakeDaily, FakeDispatcher, FakeLiveKit
from test_inbound import APP_UUID, AUTH, REGISTER_BODY, FakeApns
from test_ring_lifecycle import ALL_FEATURES, CALL_SIGNALS, FEATURED_BODY

# preconnect + call-connected: "media". preconnect only: "credentials". Neither: none.
CREDS_BODY = {**REGISTER_BODY, "push_features": ALL_FEATURES, "transport": "daily"}
PLAIN_BODY = {**REGISTER_BODY, "push_features": ["cancel", "ring_timeout"], "call_signals": CALL_SIGNALS}
STATUS_URL = "http://testserver/inbound/status/loopback"
ROOM = "room-abc"
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


def _deadline(argv):
    return float(argv[argv.index("--ring-deadline") + 1])


def _pair(c, call_id, *, joins_before_answer=True, transport="daily", call_signals=CALL_SIGNALS):
    return c.post(
        "/connect/loopback",
        json={
            "transport": transport,
            "call_signals": call_signals,
            "ring": {"call_id": call_id, "joins_before_answer": joins_before_answer},
        },
        headers=AUTH,
    )


def _receipt(c, call_id, status):
    r = c.post("/inbound/status/loopback", json={"call_id": call_id, "status": status}, headers=AUTH)
    assert r.status_code == 200, r.text


@pytest.fixture
def events(monkeypatch):
    seen = []
    monkeypatch.setattr(admin_routes, "event", lambda log, name, **fields: seen.append((name, fields)))
    return seen


def _event(events, name):
    (fields,) = [f for n, f in events if n == name]
    return fields


# --- the default pre-connect tier ---


def test_a_ring_asks_for_the_best_preconnect_the_registration_takes():
    for body, tier in ((FEATURED_BODY, "media"), (CREDS_BODY, "credentials")):
        for inline in (False, True):
            with TestClient(app) as c:
                _setup(c, body)
                r = _ring(c, inline=inline)
                assert r["preconnect"] == tier, (tier, inline)
                assert _pushed()["preconnect"] == tier
                ring = app.state.rings.get(r["call_id"])
                assert ring.preconnect == tier and ring.ring_bot
                # Either way the ring's bot is a ring bot, started at ring time.
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
            assert (r["bot_in_room"], r["bot_wait_secs"]) == (None, None)
            # Its app asks for credentials only after the answer: nothing to prepare.
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
        assert app.state.dispatcher.calls == []

        r = _ring(c, inline=True, preconnect="none")
        assert set(_pushed()) == {"agent_id", "call_id", "status_url", "room_url", "token"}
        assert r["preconnect"] is None
        argv = _argv()
        # A plain inline bot (no ring flags), still started before the push.
        assert "--ring-deadline" not in argv and "--joins-before-answer" not in argv
        assert "--report-joined" in argv and "--await-connected" in argv
        assert app.state.dispatcher.controls == [False]
        assert r["bot_in_room"] is True


def test_explicit_tiers_are_still_honoured():
    with TestClient(app) as c:
        _setup(c)
        for inline in (False, True):
            r = _ring(c, inline=inline, preconnect="credentials")
            assert r["preconnect"] == _pushed()["preconnect"] == "credentials"
            assert "--joins-before-answer" not in _argv()
            r = _ring(c, inline=inline, preconnect="media")
            assert r["preconnect"] == _pushed()["preconnect"] == "media"
            assert "--joins-before-answer" in _argv()
    with TestClient(app) as c:
        _setup(c, CREDS_BODY)
        r = _ring(c, preconnect="media")
        assert r["preconnect"] == _pushed()["preconnect"] == "credentials"


# --- agent-first: the push waits for the bot ---


def test_an_inline_ring_pushes_only_after_its_bot_reported_it_joined():
    with TestClient(app) as c:
        _setup(c)
        pushed_while_waiting = []

        async def on_wait(room):
            pushed_while_waiting.append(len(app.state.apns.sends))

        app.state.dispatcher.on_wait = on_wait
        r = _ring(c, inline=True)
        assert app.state.dispatcher.reports_joined == [True]
        assert "--report-joined" in _argv()
        assert app.state.dispatcher.waits == [(ROOM, settings.ring_bot_wait_secs)]
        assert pushed_while_waiting == [0]
        assert len(app.state.apns.sends) == 1
        assert r["bot_in_room"] is True and r["bot_wait_secs"] >= 0


def test_the_push_goes_out_after_the_bound_when_the_bot_never_joins(monkeypatch, events):
    monkeypatch.setattr(settings, "ring_bot_wait_secs", 0.2)
    for inline in (False, True):
        events.clear()
        with TestClient(app) as c:
            _setup(c)
            app.state.dispatcher.join_outcome = "timeout"
            r = _ring(c, inline=inline)
            assert len(app.state.apns.sends) == 1
            assert r["bot_in_room"] is False and r["bot_wait_secs"] >= 0.2
            assert _event(events, "ring.bot_wait")["outcome"] == "timeout"
            sent = _event(events, "ring.sent")
            assert sent["bot_in_room"] is False and sent["bot_wait_secs"] >= 0.2
            # The bot was not ended: it may still join before the user answers.
            assert app.state.dispatcher.disconnected == []


def test_a_bot_that_exits_before_joining_does_not_hold_the_ring(events):
    with TestClient(app) as c:
        _setup(c)
        app.state.dispatcher.join_outcome = "exited"
        r = _ring(c, inline=True)
        assert len(app.state.apns.sends) == 1
        assert r["bot_in_room"] is False
        assert _event(events, "ring.bot_wait")["outcome"] == "exited"


def test_wait_for_bot_false_pushes_at_once():
    with TestClient(app) as c:
        _setup(c)
        r = _ring(c, inline=True, wait_for_bot=False)
        assert app.state.dispatcher.waits == []
        assert app.state.dispatcher.reports_joined == [False]
        assert "--report-joined" not in _argv()
        assert (r["bot_in_room"], r["bot_wait_secs"]) == (None, None)
        # The bot's deadline needs no room for a wait.
        assert _deadline(_argv()) == ring_deadline_secs(None)
        # A pairing ring prepares nothing: its bot starts when the app asks.
        r = _ring(c, wait_for_bot=False)
        assert r["preconnect"] == "media"
        assert len(app.state.dispatcher.calls) == 1
        assert app.state.rings.get(r["call_id"]).room_key is None


def test_a_zero_wait_setting_turns_agent_first_ringing_off(monkeypatch):
    monkeypatch.setattr(settings, "ring_bot_wait_secs", 0)
    with TestClient(app) as c:
        _setup(c)
        r = _ring(c)
        assert app.state.dispatcher.calls == [] and r["bot_in_room"] is None
        _ring(c, inline=True)
        assert app.state.dispatcher.waits == [] and "--report-joined" not in _argv()


def test_the_wait_setting_must_not_be_negative():
    from pydantic import ValidationError

    from app.config import Settings

    with pytest.raises(ValidationError):
        Settings(ring_bot_wait_secs=-1)
    assert Settings().ring_bot_wait_secs == 8.0


def test_the_wait_does_not_shorten_the_ring_bots_deadline(monkeypatch):
    # The bot counts its deadline from its own start; the push can come up to the
    # bound later, and the user must still get the whole ring after it.
    assert ring_bot_flags(ring_timeout=30, joins_before_answer=False, push_wait_secs=8)[:2] == [
        "--ring-deadline", f"{ring_deadline_secs(30) + 8:g}",
    ]
    monkeypatch.setattr(settings, "ring_bot_wait_secs", 3)
    with TestClient(app) as c:
        _setup(c)
        _ring(c, inline=True, ring_timeout=30)
        assert _deadline(_argv()) == 30 + settings.ring_deadline_margin_secs + 3
        _ring(c, ring_timeout=30)
        assert _deadline(_argv()) == 30 + settings.ring_deadline_margin_secs + 3


def test_a_failed_push_ends_the_bot_started_for_it():
    from app.apns import ApnsResult

    for inline in (False, True):
        with TestClient(app) as c:
            _setup(c)
            app.state.apns.result = ApnsResult(status=400, reason="BadDeviceToken")
            r = c.post("/admin/ring/loopback", json={"inline": inline}, headers=AUTH)
            assert r.status_code == 502
            assert app.state.dispatcher.disconnected == [ROOM]
            assert app.state.rings.get(_pushed()["call_id"]) is None


# --- a cancel or a receipt while the ring waits for its bot ---


def _waiting_ring():
    (ring,) = [r for r in app.state.rings._rings.values() if r.awaiting_push]
    return ring


async def _post(path, body):
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://testserver") as ac:
        return await ac.post(path, json=body, headers=AUTH)


def test_a_ring_canceled_while_it_waits_is_never_pushed_and_its_bot_ends(monkeypatch):
    monkeypatch.setattr(settings, "ring_bot_wait_secs", 5)
    for inline in (False, True):
        with TestClient(app) as c:
            _setup(c)
            app.state.dispatcher.join_outcome = "timeout"  # only the cancel can end the wait
            canceled = []

            async def on_wait(room):
                ring = _waiting_ring()
                canceled.append(await _post("/admin/ring/loopback/cancel", {"call_id": ring.call_id}))

            app.state.dispatcher.on_wait = on_wait
            started = time.monotonic()
            r = c.post("/admin/ring/loopback", json={"inline": inline}, headers=AUTH)
            assert time.monotonic() - started < 3  # woken by the cancel, not the bound
            assert r.status_code == 409, r.text
            call_id = r.json()["detail"]["call_id"]
            assert r.json()["detail"] == {"call_id": call_id, "status": "canceled", "reason": RING_ENDED}
            assert app.state.apns.sends == []
            (cancel,) = canceled
            assert cancel.status_code == 200, cancel.text
            assert cancel.json()["method"] == "before_push" and cancel.json()["bot_ended"] is True
            assert app.state.dispatcher.disconnected == [ROOM]
            assert app.state.dispatcher.cancels == []
            # The ring stays known as canceled: no room for it, no second cancel.
            assert _pair(c, call_id).status_code == 409
            assert c.post("/admin/ring/loopback/cancel", json={"call_id": call_id}, headers=AUTH).status_code == 409
            assert app.state.apns.sends == []


def test_a_receipt_while_the_ring_waits_means_it_is_never_pushed(monkeypatch):
    monkeypatch.setattr(settings, "ring_bot_wait_secs", 5)
    for inline, status in ((False, "declined"), (True, "declined"), (True, "answered")):
        with TestClient(app) as c:
            _setup(c)
            app.state.dispatcher.join_outcome = "timeout"

            async def on_wait(room):
                await _post("/inbound/status/loopback", {"call_id": _waiting_ring().call_id, "status": status})

            app.state.dispatcher.on_wait = on_wait
            started = time.monotonic()
            r = c.post("/admin/ring/loopback", json={"inline": inline}, headers=AUTH)
            assert time.monotonic() - started < 3
            assert r.status_code == 409, r.text
            assert r.json()["detail"]["status"] == status
            assert app.state.apns.sends == []
            # Ended once: by the receipt, or (answered) by the ring itself.
            assert app.state.dispatcher.disconnected == [ROOM], (inline, status)


# --- pairing: the room and bot prepared at ring time ---


def test_a_pre_connected_pairing_ring_starts_its_ring_bot_before_the_push(events):
    with TestClient(app) as c:
        _setup(c)
        pushed_while_waiting = []

        async def on_wait(room):
            pushed_while_waiting.append(len(app.state.apns.sends))

        app.state.dispatcher.on_wait = on_wait
        r = _ring(c, ring_timeout=20)
        assert pushed_while_waiting == [0]
        (argv,) = [list(call[3]) for call in app.state.dispatcher.calls]
        assert _deadline(argv) == 20 + settings.ring_deadline_margin_secs + settings.ring_bot_wait_secs
        assert {"--joins-before-answer", "--await-connected", "--report-joined"} <= set(argv)
        assert app.state.dispatcher.controls == [True]
        # Still a pairing push: no credentials ride it.
        assert "room_url" not in _pushed() and "token" not in _pushed()
        assert r["mode"] == "pairing" and r["preconnect"] == "media"
        assert r["bot_in_room"] is True
        ring = app.state.rings.get(r["call_id"])
        assert (ring.room_key, ring.transport, ring.ring_bot, ring.joins_before_answer) == (ROOM, "daily", True, True)
        assert ring.prepared is not None
        assert _event(events, "ring.prepared")["room"] == ROOM


def test_the_phones_credential_request_for_the_ring_gets_the_prepared_room():
    # joins_before_answer false: the app downgraded media to credentials (its
    # transport can't join during a ring); a bot that knows the device may join
    # early serves that phone too.
    for joins_before_answer, call_id_case in ((True, str), (False, str.upper)):
        with TestClient(app) as c:
            _setup(c)
            call_id = _ring(c)["call_id"]
            r = _pair(c, call_id_case(call_id), joins_before_answer=joins_before_answer)
            assert r.status_code == 200, r.text
            assert r.json()["connection"] == PREPARED_CONNECTION
            assert r.json()["transport"] == "daily"
            assert len(app.state.dispatcher.calls) == 1  # no second bot
            assert app.state.dispatcher.disconnected == []
            assert app.state.rings.get(call_id).prepared is None  # taken


def test_a_credentials_ring_hands_over_its_prepared_room():
    with TestClient(app) as c:
        _setup(c, CREDS_BODY)
        call_id = _ring(c)["call_id"]
        argv = _argv()
        assert "--await-connected" not in argv and "--joins-before-answer" not in argv
        r = _pair(c, call_id, joins_before_answer=False, call_signals=[])
        assert r.status_code == 200, r.text
        assert len(app.state.dispatcher.calls) == 1


def test_a_request_without_a_ring_still_provisions_afresh():
    # A request after the answer (no pre-connect, a failed preparation's fallback)
    # or a reconnect carries no ring: it gets a new room, as before.
    with TestClient(app) as c:
        _setup(c)
        call_id = _ring(c)["call_id"]
        r = c.post("/connect/loopback", json={"transport": "daily", "call_signals": CALL_SIGNALS}, headers=AUTH)
        assert r.status_code == 200, r.text
        assert len(app.state.dispatcher.calls) == 2
        assert "--ring-deadline" not in _argv()
        assert app.state.rings.get(call_id).prepared is not None


def test_a_second_request_for_the_ring_gets_a_fresh_room():
    with TestClient(app) as c:
        _setup(c)
        call_id = _ring(c, ring_timeout=20)["call_id"]
        assert _pair(c, call_id).status_code == 200
        assert _pair(c, call_id).status_code == 200
        assert len(app.state.dispatcher.calls) == 2
        # A ring bot dispatched at the request, as before (no wait in its deadline).
        assert _deadline(_argv()) == 20 + settings.ring_deadline_margin_secs
        # The phone may be in the first room: it is left alone.
        assert app.state.dispatcher.disconnected == []


def test_a_request_after_the_prepared_bot_exited_gets_a_fresh_room():
    with TestClient(app) as c:
        _setup(c)
        call_id = _ring(c)["call_id"]
        app.state.dispatcher.alive.discard(ROOM)  # e.g. it crashed
        assert _pair(c, call_id).status_code == 200
        assert len(app.state.dispatcher.calls) == 2
        assert app.state.dispatcher.disconnected == []
        assert app.state.rings.get(call_id).ring_bot


def test_a_request_the_prepared_bot_does_not_fit_gets_a_fresh_room_and_ends_it():
    cases = (
        # The app dials the agent over another transport.
        ({}, {"transport": "livekit"}),
        # A credentials bot would take the phone's early join for the answer.
        ({"preconnect": "credentials"}, {"joins_before_answer": True}),
        # The prepared bot waits for a call-connected this app does not send.
        ({}, {"call_signals": []}),
    )
    for ring_body, pair_kwargs in cases:
        with TestClient(app) as c:
            _setup(c)
            call_id = _ring(c, **ring_body)["call_id"]
            r = _pair(c, call_id, **pair_kwargs)
            assert r.status_code == 200, (pair_kwargs, r.text)
            assert len(app.state.dispatcher.calls) == 2
            assert app.state.dispatcher.disconnected == [ROOM], pair_kwargs
            assert app.state.rings.get(call_id).prepared is None


CLAIM_GRACE = 0.2


@pytest.fixture
def short_claim_grace(monkeypatch):
    monkeypatch.setattr(settings, "prepared_claim_grace_secs", CLAIM_GRACE)


def test_an_answered_ring_that_never_took_its_prepared_room_ends_that_bot(short_claim_grace):
    # An app that lists preconnect but did not prepare connects after the answer
    # with a request of its own: once the claim grace is over, nothing will take
    # the prepared bot, which would wait for nobody.
    with TestClient(app) as c:
        _setup(c)
        call_id = _ring(c)["call_id"]
        _receipt(c, call_id, "answered")
        assert app.state.dispatcher.disconnected == []  # the phone may still be claiming it
        assert app.state.dispatcher.sent == [(ROOM, "answered")]
        time.sleep(CLAIM_GRACE * 3)
        assert app.state.dispatcher.disconnected == [ROOM]
        # A late request for the ring gets a fresh room (and the receipt).
        r = _pair(c, call_id)
        assert r.status_code == 200, r.text
        assert len(app.state.dispatcher.calls) == 2
        assert app.state.dispatcher.sent == [(ROOM, "answered"), (ROOM, "answered")]


def test_a_claim_in_flight_at_the_answered_receipt_still_takes_the_prepared_room(short_claim_grace):
    # The phone answers while its ring-time request is still on the way (a cold
    # launch answered quickly) and the receipt lands first: the request must get
    # the agent already in the room, not a fresh room and a cold agent.
    with TestClient(app) as c:
        _setup(c)
        call_id = _ring(c)["call_id"]
        _receipt(c, call_id, "answered")
        r = _pair(c, call_id)
        assert r.status_code == 200, r.text
        assert r.json()["connection"] == PREPARED_CONNECTION
        assert len(app.state.dispatcher.calls) == 1  # no cold agent
        # The bot heard of the answer from the receipt, once.
        assert app.state.dispatcher.sent == [(ROOM, "answered")]
        time.sleep(CLAIM_GRACE * 3)
        assert app.state.dispatcher.disconnected == []  # taken: the grace ends nothing


def test_the_claim_grace_is_a_setting_of_ten_seconds_by_default():
    assert type(settings).model_fields["prepared_claim_grace_secs"].default == 10.0


def test_a_taken_prepared_room_gets_the_answered_receipt():
    with TestClient(app) as c:
        _setup(c)
        call_id = _ring(c)["call_id"]
        assert _pair(c, call_id).status_code == 200
        _receipt(c, call_id, "answered")
        assert app.state.dispatcher.sent == [(ROOM, "answered")]
        assert app.state.dispatcher.disconnected == []


def test_a_prepared_ring_that_ends_unanswered_ends_its_bot_and_refuses_the_room():
    for status in ("declined", "unanswered", "busy"):
        with TestClient(app) as c:
            _setup(c)
            call_id = _ring(c)["call_id"]
            _receipt(c, call_id, status)
            assert app.state.dispatcher.disconnected == [ROOM]
            r = _pair(c, call_id)
            assert r.status_code == 409
            assert r.json()["detail"] == {"call_id": call_id, "status": status, "reason": RING_ENDED}
            assert len(app.state.dispatcher.calls) == 1


def test_canceling_a_prepared_ring_asks_its_bot():
    with TestClient(app) as c:
        _setup(c)
        call_id = _ring(c)["call_id"]
        r = c.post("/admin/ring/loopback/cancel", json={"call_id": call_id}, headers=AUTH)
        assert r.status_code == 200, r.text
        assert r.json()["bot_ended"] is True
        assert app.state.dispatcher.cancels == [ROOM]
        assert _pair(c, call_id).status_code == 409


def test_smallwebrtc_rings_prepare_nothing():
    # No room to prepare: its bot starts in-process when the app's offer lands.
    with TestClient(app) as c:
        _setup(c)
        r = _ring(c, transport="smallwebrtc")
        assert r["preconnect"] == "media"
        assert app.state.dispatcher.calls == [] and app.state.dispatcher.waits == []
        assert (r["bot_in_room"], r["bot_wait_secs"]) == (None, None)


# --- the transport of the room prepared at ring time: the phone's ---


def test_a_ring_prepares_its_room_on_the_transport_the_phone_registered(events):
    # The app registers "livekit" for a LiveKit agent (the value of its pairing
    # body's "transport"): the ring's room is LiveKit, whatever the server's default,
    # and the phone's LiveKit request during the ring takes it.
    with TestClient(app) as c:
        _setup(c, {**FEATURED_BODY, "transport": "livekit"})
        r = _ring(c)
        assert r["transport"] == "livekit" and r["bot_in_room"] is True
        ((_, _, transport, _),) = app.state.dispatcher.calls
        assert transport == "livekit"
        pair = _pair(c, r["call_id"], transport="livekit")
        assert pair.status_code == 200, pair.text
        assert pair.json()["transport"] == "livekit"
        assert len(app.state.dispatcher.calls) == 1  # the prepared bot, not a cold one
        assert app.state.dispatcher.disconnected == []
        assert _event(events, "ring.prepared")["transport"] == "livekit"


def test_the_ring_requests_transport_wins_over_the_registration():
    with TestClient(app) as c:
        _setup(c, {**FEATURED_BODY, "transport": "livekit"})
        r = _ring(c, transport="daily")
        assert r["transport"] == "daily"
        assert [call[2] for call in app.state.dispatcher.calls] == ["daily"]


def test_a_registration_without_a_transport_prepares_nothing_and_waits_for_nothing(events):
    # An older app registers no transport: a room made now could be the wrong
    # kind, which the phone's request would find unfit (a delayed ring, then a
    # cold start after all). Its request during the ring makes the room instead.
    body = {k: v for k, v in FEATURED_BODY.items() if k != "transport"}
    with TestClient(app) as c:
        _setup(c, body)
        r = _ring(c)
        assert r["preconnect"] == "media"
        assert (r["bot_in_room"], r["bot_wait_secs"], r["transport"]) == (None, None, None)
        assert app.state.dispatcher.calls == [] and app.state.dispatcher.waits == []
        assert len(app.state.apns.sends) == 1
        assert _event(events, "ring.transport_unknown") == {"agent": "loopback", "inline": False}
        pair = _pair(c, r["call_id"], transport="livekit")
        assert pair.status_code == 200, pair.text
        assert [call[2] for call in app.state.dispatcher.calls] == ["livekit"]


def test_an_inline_ring_without_a_known_transport_uses_the_agents_default():
    body = {k: v for k, v in FEATURED_BODY.items() if k != "transport"}
    with TestClient(app) as c:
        _setup(c, body)
        r = _ring(c, inline=True)
        assert r["transport"] == "daily"
        assert _pushed()["room_url"] == PREPARED_CONNECTION["room_url"]


def test_a_smallwebrtc_phone_rings_with_nothing_prepared():
    # The check is on the phone's transport (registered), not the server's default.
    with TestClient(app) as c:
        _setup(c, {**FEATURED_BODY, "transport": "smallwebrtc"})
        r = _ring(c)
        assert r["preconnect"] == "media" and r["transport"] is None
        assert app.state.dispatcher.calls == [] and app.state.dispatcher.waits == []


def test_a_registration_naming_an_unknown_transport_is_kept_without_it():
    with TestClient(app) as c:
        _setup(c, {**FEATURED_BODY, "transport": "carrier-pigeon"})
        assert asyncio.run(app.state.registry.get_voip("loopback")).transport is None
        r = _ring(c)
        assert r["transport"] is None and app.state.dispatcher.calls == []


def test_a_preparation_that_fails_still_rings(events):
    with TestClient(app) as c:
        _setup(c)
        app.state.daily = None  # Daily not configured: the app's request will 503
        r = _ring(c)
        assert len(app.state.apns.sends) == 1
        assert r["preconnect"] == "media" and r["bot_in_room"] is None
        assert app.state.dispatcher.calls == []
        assert "Daily is not configured" in _event(events, "ring.prepare_failed")["error"]


# --- end to end over the real dispatcher (a fake bot subprocess) ---


class FakeBot:
    """A bot subprocess: says it joined only when told to."""

    def __init__(self, argv, kwargs):
        self.argv = list(argv)
        self.kwargs = kwargs
        self.pid = 4321
        self.returncode = None
        self.stdin = _Stdin()
        self.stdout = asyncio.StreamReader()
        self.terminated = False
        self._done = asyncio.Event()

    def join(self):
        self.stdout.feed_data(f"{CONTROL_REPLY_PREFIX}{CONTROL_JOINED}\n".encode())

    async def wait(self):
        await self._done.wait()
        return 0

    def terminate(self):
        self.terminated = True
        self.finish()

    def finish(self):
        if not self._done.is_set():
            self.returncode = 0
            self.stdout.feed_eof()
            self._done.set()


class _Stdin:
    def write(self, data):
        pass

    async def drain(self):
        pass


class RoomPerCallDaily(FakeDaily):
    """A new room per call, as Daily makes (the real dispatcher would otherwise
    see the last test bot still in the room and skip the dispatch)."""

    def __init__(self):
        self.made = 0

    async def create_room(self, *, exp_secs, name=None):
        from test_connect_flow import _FakeRoom

        self.made += 1
        return _FakeRoom(f"room-{self.made}", f"https://x.daily.co/room-{self.made}")


@pytest.fixture
async def engine(monkeypatch):
    bots = []

    async def fake_exec(*argv, **kwargs):
        bots.append(FakeBot(argv, kwargs))
        return bots[-1]

    monkeypatch.setattr(asyncio, "create_subprocess_exec", fake_exec)
    registry = SQLiteRegistry(":memory:")
    state = app.state
    state.registry = registry
    state.dispatcher = Dispatcher(registry)
    state.daily = RoomPerCallDaily()
    state.livekit = FakeLiveKit()
    state.apns = FakeApns()
    state.rings = RingTracker()
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://testserver") as ac:
        r = await ac.post("/inbound/register/loopback", json=FEATURED_BODY, headers=AUTH)
        assert r.status_code == 200
        yield ac, bots
    for bot in bots:
        bot.finish()
    await asyncio.sleep(0.01)
    registry.close()


async def _started(bots):
    for _ in range(200):
        if bots:
            return bots[0]
        await asyncio.sleep(0.01)
    raise AssertionError("no bot was dispatched")


async def test_end_to_end_the_push_follows_the_bots_joined_line(engine):
    ac, bots = engine
    for body in ({"inline": True}, {}):
        bots.clear()
        app.state.apns.sends.clear()
        task = asyncio.create_task(ac.post("/admin/ring/loopback", json=body, headers=AUTH))
        bot = await _started(bots)
        await asyncio.sleep(0.15)
        assert not task.done() and app.state.apns.sends == []
        assert "--report-joined" in bot.argv
        assert bot.kwargs["stdout"] is asyncio.subprocess.PIPE
        bot.join()
        r = await asyncio.wait_for(task, 2)
        assert r.status_code == 200, r.text
        assert r.json()["bot_in_room"] is True and r.json()["bot_wait_secs"] >= 0.15
        assert len(app.state.apns.sends) == 1

    # The pairing ring's room goes to the phone's request for it: no second bot.
    call_id = r.json()["call_id"]
    r = await ac.post(
        "/connect/loopback",
        json={"transport": "daily", "call_signals": CALL_SIGNALS, "ring": {"call_id": call_id, "joins_before_answer": True}},
        headers=AUTH,
    )
    assert r.status_code == 200, r.text
    assert r.json()["connection"] == {"room_url": "https://x.daily.co/room-2", "token": "token-app"}
    assert len(bots) == 1


async def test_end_to_end_the_bound_and_a_bot_that_dies(engine, monkeypatch):
    ac, bots = engine
    monkeypatch.setattr(settings, "ring_bot_wait_secs", 0.3)
    r = await ac.post("/admin/ring/loopback", json={"inline": True}, headers=AUTH)
    assert r.status_code == 200
    assert r.json()["bot_in_room"] is False and r.json()["bot_wait_secs"] >= 0.3
    assert not bots[0].terminated

    monkeypatch.setattr(settings, "ring_bot_wait_secs", 8)
    bots.clear()
    task = asyncio.create_task(ac.post("/admin/ring/loopback", json={"inline": True}, headers=AUTH))
    bot = await _started(bots)
    started = time.monotonic()
    bot.finish()  # crashed while starting
    r = await asyncio.wait_for(task, 2)
    assert time.monotonic() - started < 1
    assert r.json()["bot_in_room"] is False
    assert len(app.state.apns.sends) == 2


async def test_end_to_end_a_cancel_during_the_wait(engine):
    ac, bots = engine
    task = asyncio.create_task(ac.post("/admin/ring/loopback", json={"inline": True}, headers=AUTH))
    bot = await _started(bots)
    await asyncio.sleep(0.05)
    ring = _waiting_ring()
    r = await ac.post("/admin/ring/loopback/cancel", json={"call_id": ring.call_id}, headers=AUTH)
    assert r.status_code == 200, r.text
    assert r.json() == {"call_id": ring.call_id, "method": "before_push", "bot_ended": True,
                        "apns_status": None, "apns_id": None}
    assert bot.terminated
    r = await asyncio.wait_for(task, 2)
    assert r.status_code == 409
    assert app.state.apns.sends == []
