"""A bot nobody ever joins ends itself (HUMAN_JOIN_TIMEOUT_SECS), on every dispatch
path, instead of waiting out PIPELINE_IDLE_TIMEOUT_SECS (30 min) as a billed
participant: the user hung up while pairing was in flight, the phone abandoned a
prepared room, a direct-mode caller left before the bot arrived. A bot still
waiting for its ring is governed by its ring deadline instead; once the ring is
answered without the phone in the room, the bound starts from the answer."""

import asyncio

import pytest
from fastapi.testclient import TestClient

from app.config import Settings, settings
from app.main import app
from app.obs import get_logger
from app.provisioning import dispatch_for_webhook
from app.registry import RoomRecord
from app.rings import ring_deadline_secs
from bot.call_control import CallControl
from bot.runtime import _presence_probe
from bot.teardown import TeardownController

from test_connect_flow import FakeDaily, FakeDispatcher, FakeLiveKit
from test_inbound import AUTH, REGISTER_BODY, FakeApns
from test_ring_lifecycle import ALL_FEATURES, CALL_SIGNALS, FEATURED_BODY

_log = get_logger("test")


class FakeWorker:
    def __init__(self):
        self.cancelled = 0

    async def cancel(self):
        self.cancelled += 1


def _make(*, join_timeout=0.05, deadline=None, joins_before_answer=False, others_present=None):
    worker = FakeWorker()
    teardown = TeardownController(worker, grace_secs=100, log=_log)
    call = CallControl(
        teardown=teardown,
        greet=None,
        await_connected=True,
        joins_before_answer=joins_before_answer,
        ring_deadline_secs=deadline,
        join_timeout_secs=join_timeout,
        others_present=others_present,
        log=_log,
    )
    call.start()
    return call, worker


# --- the bot side ---


async def test_a_bot_nobody_joins_ends_itself():
    call, worker = _make()
    await asyncio.sleep(0.15)
    assert worker.cancelled == 1
    call.stop()


async def test_a_human_joining_keeps_the_bot_for_good():
    call, worker = _make()
    await call.human_joined("phone")
    call.human_left("phone")  # the grace window governs from here, not the join bound
    await asyncio.sleep(0.15)
    assert worker.cancelled == 0
    call.stop()


async def test_a_ready_client_counts_as_a_human():
    # Daily may not report a participant that was in the room before the bot.
    call, worker = _make()
    await call.client_ready()
    await asyncio.sleep(0.15)
    assert worker.cancelled == 0
    call.stop()


async def test_call_connected_counts_as_a_human():
    call, worker = _make()
    await call.handle("call-connected")
    await asyncio.sleep(0.15)
    assert worker.cancelled == 0
    call.stop()


async def test_a_human_the_transport_still_lists_keeps_the_bot():
    call, worker = _make(others_present=lambda: True)
    await asyncio.sleep(0.15)
    assert worker.cancelled == 0
    call.stop()


async def test_zero_turns_the_bound_off():
    call, worker = _make(join_timeout=0)
    await asyncio.sleep(0.1)
    assert worker.cancelled == 0
    call.stop()


async def test_a_ringing_bot_is_governed_by_its_ring_deadline_not_the_join_bound():
    call, worker = _make(join_timeout=0.05, deadline=0.3, joins_before_answer=True)
    await asyncio.sleep(0.15)
    assert worker.cancelled == 0  # still ringing: the join bound does not apply
    await asyncio.sleep(0.25)
    assert worker.cancelled == 1  # the ring deadline ended it
    call.stop()


async def test_an_answered_ring_without_the_phone_ends_after_the_bound_from_the_answer():
    # The phone answered (receipt) but never came to this room: e.g. it abandoned
    # the prepared room and connected through a fresh request.
    call, worker = _make(join_timeout=0.1, deadline=10)
    await asyncio.sleep(0.15)
    assert worker.cancelled == 0
    await call.receipt_answered()
    await asyncio.sleep(0.05)
    assert worker.cancelled == 0
    await asyncio.sleep(0.1)
    assert worker.cancelled == 1
    call.stop()


async def test_an_answered_ring_the_phone_joins_is_kept():
    call, worker = _make(join_timeout=0.05, deadline=10)
    await call.receipt_answered()
    await call.human_joined("phone")
    await asyncio.sleep(0.15)
    assert worker.cancelled == 0
    call.stop()


def test_presence_probes_count_anyone_but_the_bot():
    class Daily:
        def __init__(self, p):
            self.p = p

        def participants(self):
            return self.p

    class LiveKit:
        def __init__(self, p):
            self.p = p

        def get_participants(self):
            return self.p

    class Broken:
        def participants(self):
            raise RuntimeError("down")

    assert _presence_probe(Daily({"local": {}}), "daily")() is False
    assert _presence_probe(Daily({"local": {}, "abc": {}}), "daily")() is True
    assert _presence_probe(LiveKit([]), "livekit")() is False
    assert _presence_probe(LiveKit(["PA_1"]), "livekit")() is True
    # Can't tell: never end a call on a broken probe.
    assert _presence_probe(Broken(), "daily")() is True
    assert _presence_probe(object(), "smallwebrtc") is None


def test_the_bound_is_a_setting_covering_the_phones_30_second_join_deadline():
    assert Settings.model_fields["human_join_timeout_secs"].default == 45.0
    assert Settings.model_fields["human_join_timeout_secs"].default > 30


# --- every dispatch path hands its bot a bound ---


def _join_timeout(argv):
    argv = list(argv)
    return float(argv[argv.index("--join-timeout") + 1])


@pytest.mark.parametrize("transport", ["daily", "livekit"])
def test_a_pairing_bot_gets_the_join_bound(transport):
    with TestClient(app) as c:
        app.state.daily = FakeDaily()
        app.state.livekit = FakeLiveKit()
        app.state.dispatcher = FakeDispatcher()
        r = c.post("/connect/loopback", json={"transport": transport}, headers=AUTH)
        assert r.status_code == 200, r.text
        ((_, _, _, argv),) = app.state.dispatcher.calls
        assert _join_timeout(argv) == settings.human_join_timeout_secs
        assert "--ring-deadline" not in argv


async def test_a_webhook_bot_gets_the_join_bound():
    class State:
        daily = FakeDaily()
        livekit = FakeLiveKit()
        dispatcher = FakeDispatcher()

    for record in (
        RoomRecord(room_key="room-abc", agent_id="loopback", transport="daily", room_url="https://x.daily.co/room-abc"),
        RoomRecord(room_key="conduit-1", agent_id="loopback", transport="livekit", room_url=None),
    ):
        await dispatch_for_webhook(State, record)
    for _, _, _, argv in State.dispatcher.calls:
        assert _join_timeout(argv) == settings.human_join_timeout_secs


def _ring_setup(c, body):
    app.state.daily = FakeDaily()
    app.state.livekit = FakeLiveKit()
    app.state.dispatcher = FakeDispatcher()
    app.state.apns = FakeApns()
    assert c.post("/inbound/register/loopback", json=body, headers=AUTH).status_code == 200


def test_a_plain_inline_bot_waits_for_the_phone_as_long_as_the_ring_can_last():
    # No preconnect: no ring deadline, and the phone joins only after the answer,
    # so its join bound covers the whole ring.
    with TestClient(app) as c:
        _ring_setup(c, {**REGISTER_BODY, "transport": "daily"})
        r = c.post("/admin/ring/loopback", json={"inline": True, "wait_for_bot": False}, headers=AUTH)
        assert r.status_code == 200, r.text
        ((_, _, _, argv),) = app.state.dispatcher.calls
        assert "--ring-deadline" not in argv
        assert _join_timeout(argv) == ring_deadline_secs(None)


@pytest.mark.parametrize("inline", [True, False])
def test_a_ring_bot_gets_its_deadline_and_the_join_bound_for_after_the_answer(inline):
    # Inline with preconnect, and a pairing ring's bot prepared at ring time.
    with TestClient(app) as c:
        _ring_setup(c, FEATURED_BODY)
        r = c.post("/admin/ring/loopback", json={"inline": inline}, headers=AUTH)
        assert r.status_code == 200, r.text
        ((_, _, _, argv),) = app.state.dispatcher.calls
        assert "--ring-deadline" in argv
        assert _join_timeout(argv) == settings.human_join_timeout_secs


def test_a_ring_bot_dispatched_at_the_phones_request_gets_the_bound_too():
    with TestClient(app) as c:
        _ring_setup(c, {**REGISTER_BODY, "push_features": ALL_FEATURES, "call_signals": CALL_SIGNALS})
        r = c.post(
            "/connect/loopback",
            json={"transport": "daily", "call_signals": CALL_SIGNALS, "ring": {"call_id": "abc"}},
            headers=AUTH,
        )
        assert r.status_code == 200, r.text
        ((_, _, _, argv),) = app.state.dispatcher.calls
        assert "--ring-deadline" in argv
        assert _join_timeout(argv) == settings.human_join_timeout_secs


async def test_the_cli_passes_the_join_bound_to_run_bot(monkeypatch):
    import sys

    import bot.bot as entry

    seen = {}

    async def fake_run_bot(transport, agent_id, transport_type, **kwargs):
        seen.update(kwargs)

    monkeypatch.setattr(entry, "build_transport", lambda kind, creds: object())
    monkeypatch.setattr(entry, "run_bot", fake_run_bot)
    monkeypatch.setattr(sys, "argv", [
        "bot", "--transport", "daily", "--agent", "live", "--token", "t", "--room-url", "https://x",
        "--join-timeout", "83",
    ])
    await entry._run_from_cli()
    assert seen["join_timeout_secs"] == 83
