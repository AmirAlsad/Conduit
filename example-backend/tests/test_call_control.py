"""Bot-side call control: when the agent may speak (call-connected, for a client
that sends it, with its fallback), the ring deadline, hold/resume, and how each
transport's wiring delivers the signals (bot/call_control.py)."""

import asyncio
import json

from pipecat.frames.frames import (
    InputAudioRawFrame,
    OutputAudioRawFrame,
    TextFrame,
)
from pipecat.processors.frame_processor import FrameDirection

from app.obs import get_logger
from app.rings import CONTROL_REPLY_PREFIX
from bot.call_control import AudioGate, CallControl
from bot.runtime import _read_control, _wire_presence, _wire_rtvi, reply_on_stdout
from bot.teardown import TeardownController

_log = get_logger("test")


class FakeWorker:
    def __init__(self):
        self.cancelled = 0

    async def cancel(self):
        self.cancelled += 1


class FakeGate:
    def __init__(self):
        self.is_open = True
        self.interrupts = 0

    def open(self):
        self.is_open = True

    def close(self):
        self.is_open = False

    async def interrupt(self):
        self.interrupts += 1


class FakeEvents:
    """Mimics pipecat's @x.event_handler registration (transports and RTVI)."""

    def __init__(self):
        self.handlers = {}

    def event_handler(self, name):
        def deco(fn):
            self.handlers[name] = fn
            return fn

        return deco


class Greeter:
    def __init__(self):
        self.count = 0

    async def __call__(self):
        self.count += 1


class RtviMessage:
    def __init__(self, type_):
        self.type = type_


def _make(
    *,
    await_connected=False,
    joins_before_answer=False,
    deadline=None,
    gates=None,
    grace=100.0,
    connected_grace=0.0,
):
    worker = FakeWorker()
    teardown = TeardownController(worker, grace_secs=grace, log=_log, held_grace_secs=0.3)
    greet = Greeter()
    gates = [FakeGate(), FakeGate()] if gates is None else gates
    call = CallControl(
        teardown=teardown,
        greet=greet,
        gates=gates,
        await_connected=await_connected,
        joins_before_answer=joins_before_answer,
        ring_deadline_secs=deadline,
        connected_grace_secs=connected_grace,
        log=_log,
    )
    return call, teardown, worker, greet, gates


def _media_ring(**kwargs):
    """A "media" ring bot for a client that sends call-connected: the phone joins
    while it still rings."""
    return _make(await_connected=True, joins_before_answer=True, deadline=60, **kwargs)


def _lk_wire(data_t):
    return json.dumps(
        {"id": "x1", "label": "rtvi-ai", "type": "client-message", "data": {"t": data_t}}
    ).encode()


# --- a client that does not send call-connected: today's behaviour ---


async def test_without_call_connected_every_client_ready_greets_and_gates_stay_open():
    call, _, _, greet, gates = _make()
    assert call.answered and call.on_line
    await call.client_ready()
    await call.client_ready()
    assert greet.count == 2  # unchanged: each RTVI client-ready greets
    assert all(g.is_open for g in gates)


async def test_a_call_connected_from_a_client_that_never_listed_it_changes_nothing():
    call, _, _, greet, gates = _make()
    await call.client_ready()
    await call.handle("call-connected")
    assert greet.count == 1
    assert all(g.is_open for g in gates)


# --- a client that sends call-connected: greet on it, on every call ---


async def test_an_outgoing_call_is_silent_until_call_connected_then_greets_once():
    call, _, _, greet, gates = _make(await_connected=True, connected_grace=60)
    assert call.answered and not call.on_line
    assert not any(g.is_open for g in gates)
    await call.human_joined("phone")
    await call.client_ready()  # the app is in the room, playing its ringback
    assert greet.count == 0
    assert not any(g.is_open for g in gates)
    await call.handle("call-connected")
    assert call.on_line
    assert all(g.is_open for g in gates)
    assert greet.count == 1
    # The app sends it again after every reconnect: the same call, no second greeting.
    await call.handle("call-connected")
    await call.client_ready()
    assert greet.count == 1
    call.stop()


async def test_call_connected_before_client_ready_greets_at_once():
    # The client can hear the bot by the time it says the user is on the line.
    call, _, _, greet, _ = _make(await_connected=True, connected_grace=60)
    await call.handle("call-connected")
    assert greet.count == 1
    await call.client_ready()
    assert greet.count == 1
    call.stop()


async def test_a_lost_call_connected_is_covered_once_the_device_is_in_the_room():
    call, _, _, greet, gates = _make(await_connected=True, connected_grace=0.1)
    await asyncio.sleep(0.2)
    assert greet.count == 0  # nobody in the room yet
    await call.human_joined("phone")
    await call.client_ready()
    await asyncio.sleep(0.05)
    assert not call.on_line
    await asyncio.sleep(0.1)
    assert call.on_line and greet.count == 1
    assert all(g.is_open for g in gates)
    await call.handle("call-connected")  # late: the next connection's, nothing new
    assert greet.count == 1
    call.stop()


async def test_call_connected_inside_the_fallback_wait_greets_once():
    call, _, _, greet, _ = _make(await_connected=True, connected_grace=0.1)
    await call.human_joined("phone")
    await call.client_ready()
    await call.handle("call-connected")
    assert greet.count == 1
    await asyncio.sleep(0.2)
    assert greet.count == 1
    call.stop()


# --- rings ---


async def test_a_media_ring_is_silent_until_call_connected_then_greets_once():
    call, _, _, greet, gates = _media_ring()
    assert not any(g.is_open for g in gates)
    await call.client_ready()  # the phone joined while ringing
    assert greet.count == 0 and not call.answered
    await call.handle("call-connected")
    assert call.answered and call.on_line
    assert all(g.is_open for g in gates)
    assert greet.count == 1
    await call.handle("call-connected")
    await call.client_ready()
    assert greet.count == 1
    call.stop()


async def test_a_media_ring_ignores_the_human_joining():
    call, _, _, _, gates = _media_ring()
    assert await call.human_joined() is True
    assert await call.human_joined() is False
    assert not call.answered
    assert not any(g.is_open for g in gates)
    call.stop()


async def test_a_ring_that_joins_before_the_answer_stays_silent_for_any_client():
    # A client that never listed call-connected still joins before the answer on
    # a "media" ring: the bot must not speak to a phone that is still ringing.
    call, _, _, greet, gates = _make(joins_before_answer=True, deadline=60)
    await call.client_ready()
    assert greet.count == 0
    assert not any(g.is_open for g in gates)
    call.stop()


async def test_ring_deadline_ends_an_unanswered_bot():
    call, _, worker, greet, _ = _make(await_connected=True, joins_before_answer=True, deadline=0.05)
    call.start()
    await asyncio.sleep(0.15)
    assert worker.cancelled == 1
    assert greet.count == 0


async def test_call_connected_cancels_the_ring_deadline():
    call, _, worker, _, _ = _make(await_connected=True, joins_before_answer=True, deadline=0.05)
    call.start()
    await call.handle("call-connected")
    await asyncio.sleep(0.15)
    assert worker.cancelled == 0


async def test_ring_bot_that_the_app_joins_after_the_answer_takes_the_join_as_the_answer():
    # preconnect: credentials -- the app joins only after the user answered.
    call, _, worker, _, gates = _make(deadline=0.05)
    assert all(g.is_open for g in gates)
    call.start()
    await call.human_joined()
    assert call.answered
    await asyncio.sleep(0.15)
    assert worker.cancelled == 0


async def test_a_credentials_ring_for_a_client_that_sends_call_connected_waits_for_it():
    call, _, worker, greet, gates = _make(await_connected=True, deadline=0.05, connected_grace=60)
    call.start()
    await call.human_joined("phone")  # the join is the answer: the deadline stops
    await call.client_ready()
    await asyncio.sleep(0.15)
    assert worker.cancelled == 0
    assert greet.count == 0 and not any(g.is_open for g in gates)
    await call.handle("call-connected")
    assert greet.count == 1
    call.stop()


# --- hold ---


async def test_hold_closes_gates_interrupts_and_resume_reopens():
    call, teardown, _, _, gates = _make()
    await call.handle("call-held")
    assert call.held
    assert not any(g.is_open for g in gates)
    assert gates[0].interrupts == 1
    await call.handle("call-held")  # repeated: no second interruption
    assert gates[0].interrupts == 1
    await call.handle("call-resumed")
    assert not call.held
    assert all(g.is_open for g in gates)


async def test_a_call_that_connects_while_held_hears_resumed_then_connected():
    # The engine's order for a call that connects during a hold.
    call, _, _, greet, gates = _make(await_connected=True, connected_grace=60)
    await call.handle("call-held")
    await call.handle("call-resumed")
    assert not any(g.is_open for g in gates)  # resumed, but not on the line yet
    assert greet.count == 0
    await call.handle("call-connected")
    assert all(g.is_open for g in gates)
    assert greet.count == 1
    call.stop()


async def test_call_connected_says_the_call_is_not_held():
    # It is never sent while held: a call-resumed lost on the way is implied by it.
    call, teardown, _, _, gates = _make(await_connected=True, connected_grace=60)
    await call.handle("call-connected")
    await call.handle("call-held")
    await call.handle("call-connected")  # a reconnect after a resume the bot missed
    assert not call.held
    assert all(g.is_open for g in gates)
    call.stop()


async def test_the_fallback_neither_releases_nor_greets_while_held():
    # The app tells the bot of a hold as soon as it is in the room, even while the
    # call still shows connecting: the fallback must not greet into a held call
    # (an outgoing one held during its minimum, or an answered one still
    # connecting), nor greet behind a closed output gate.
    call, _, _, greet, gates = _make(await_connected=True, connected_grace=0.05)
    await call.human_joined("phone")
    await call.client_ready()
    await call.handle("call-held")
    await asyncio.sleep(0.1)
    assert call.held and not call.on_line
    assert greet.count == 0
    assert not any(g.is_open for g in gates)
    # The resume starts the wait again in full; the app's call-connected wins it.
    await call.handle("call-resumed")
    await asyncio.sleep(0.02)
    assert greet.count == 0
    await call.handle("call-connected")
    assert call.on_line and greet.count == 1
    assert all(g.is_open for g in gates)
    await asyncio.sleep(0.1)
    assert greet.count == 1
    call.stop()


async def test_a_lost_call_connected_after_a_hold_is_covered_from_the_resume():
    call, _, _, greet, gates = _make(await_connected=True, connected_grace=0.05)
    await call.human_joined("phone")
    await call.client_ready()
    await asyncio.sleep(0.03)  # part of the wait, then the hold stops it
    await call.handle("call-held")
    await asyncio.sleep(0.1)
    assert greet.count == 0
    await call.handle("call-resumed")
    await asyncio.sleep(0.03)
    assert greet.count == 0  # in full from the resume, not the rest of the first wait
    await asyncio.sleep(0.05)
    assert call.on_line and greet.count == 1
    assert all(g.is_open for g in gates)
    call.stop()


async def test_a_bot_on_the_line_that_has_not_greeted_greets_at_the_resume():
    # Released by the fallback before the client was ready (no greeting yet), then
    # held: the client becoming ready during the hold greets no one until the resume.
    call, _, _, greet, gates = _make(await_connected=True, connected_grace=0.05)
    await call.human_joined("phone")
    await asyncio.sleep(0.1)
    assert call.on_line and greet.count == 0
    await call.handle("call-held")
    await call.client_ready()
    assert greet.count == 0
    await call.handle("call-resumed")
    assert greet.count == 1
    assert all(g.is_open for g in gates)
    await call.handle("call-connected")
    assert greet.count == 1
    call.stop()


async def test_the_answered_receipt_during_a_hold_waits_for_the_resume():
    call, _, _, greet, _ = _media_ring(connected_grace=0.05)
    await call.client_ready()
    await call.handle("call-held")
    await call.receipt_answered()
    await asyncio.sleep(0.1)
    assert call.answered and not call.on_line and greet.count == 0
    await call.handle("call-resumed")
    await asyncio.sleep(0.1)
    assert call.on_line and greet.count == 1
    call.stop()


async def test_human_leaving_while_held_gets_the_held_grace():
    call, teardown, worker, _, _ = _make(grace=0.05)
    teardown.human_joined("a")
    await call.handle("call-held")
    teardown.human_left("a")
    await asyncio.sleep(0.15)
    assert worker.cancelled == 0  # the 0.05 s window would have ended it
    await asyncio.sleep(0.3)
    assert worker.cancelled == 1  # the held window (0.3 s) did


async def test_unknown_signal_is_not_handled():
    call, _, _, _, _ = _make()
    assert await call.handle("something-else") is False


# --- the audio gate itself ---


async def test_audio_gate_drops_audio_only_while_closed():
    gate = AudioGate()
    passed = []

    async def capture(frame, direction=FrameDirection.DOWNSTREAM):
        passed.append(frame)

    gate.push_frame = capture
    frames = [
        InputAudioRawFrame(audio=b"\x00\x00" * 160, sample_rate=16000, num_channels=1),
        OutputAudioRawFrame(audio=b"\x00\x00" * 160, sample_rate=16000, num_channels=1),
        TextFrame(text="hi"),
    ]
    gate.close()
    for f in frames:
        await gate.process_frame(f, FrameDirection.DOWNSTREAM)
    assert [type(f) for f in passed] == [TextFrame]
    gate.open()
    passed.clear()
    for f in frames:
        await gate.process_frame(f, FrameDirection.DOWNSTREAM)
    assert len(passed) == 3


# --- transport wiring ---


async def test_livekit_first_join_greets_without_a_ring():
    # LiveKit's app sends no client-ready, so `live` never greeted there before.
    call, teardown, _, greet, _ = _make()
    t = FakeEvents()
    _wire_presence(t, "livekit", teardown, call, _log)
    await t.handlers["on_participant_connected"](t, "user-1")
    assert greet.count == 1
    await t.handlers["on_participant_left"](t, "user-1", "disconnected")
    await t.handlers["on_participant_connected"](t, "user-1")  # reconnect: no re-greet
    assert greet.count == 1


async def test_livekit_raw_call_connected_releases_an_awaiting_bot():
    call, teardown, worker, greet, gates = _media_ring()
    t = FakeEvents()
    _wire_presence(t, "livekit", teardown, call, _log)
    await t.handlers["on_participant_connected"](t, "user-1")  # joined while ringing
    assert greet.count == 0
    await t.handlers["on_data_received"](t, _lk_wire("call-connected"), "user-1")
    assert greet.count == 1
    assert all(g.is_open for g in gates)
    await t.handlers["on_data_received"](t, _lk_wire("call-held"), "user-1")
    assert call.held
    await t.handlers["on_data_received"](t, _lk_wire("call-resumed"), "user-1")
    assert not call.held
    await t.handlers["on_data_received"](t, _lk_wire("end-call"), "user-1")
    assert worker.cancelled == 1
    call.stop()


async def test_daily_signals_arrive_through_rtvi():
    call, teardown, worker, greet, gates = _media_ring()
    t, rtvi = FakeEvents(), FakeEvents()
    _wire_presence(t, "daily", teardown, call, _log)
    _wire_rtvi(rtvi, teardown, call, "live", _log)
    await t.handlers["on_participant_joined"](t, {"id": "p1"})
    await rtvi.handlers["on_client_ready"](rtvi)
    assert greet.count == 0
    await rtvi.handlers["on_client_message"](rtvi, RtviMessage("call-connected"))
    assert greet.count == 1
    await rtvi.handlers["on_client_message"](rtvi, RtviMessage("call-held"))
    assert not any(g.is_open for g in gates)
    await rtvi.handlers["on_client_message"](rtvi, RtviMessage("end-call"))
    assert worker.cancelled == 1
    call.stop()


async def test_daily_join_answers_a_ring_bot_that_does_not_await():
    call, teardown, _, _, _ = _make(deadline=60)
    t = FakeEvents()
    _wire_presence(t, "daily", teardown, call, _log)
    await t.handlers["on_participant_joined"](t, {"id": "p1"})
    assert call.answered


async def test_control_line_answered_is_the_receipt():
    call, _, _, greet, _ = _media_ring(connected_grace=0)
    await call.client_ready()

    async def lines():
        yield "noise"
        yield "answered"

    await _read_control(lines(), call, _log)
    assert call.answered and call.on_line  # a zero grace releases at once
    assert greet.count == 1
    call.stop()


async def test_smallwebrtc_client_presence_reaches_the_fallback():
    call, teardown, _, greet, _ = _make(await_connected=True, connected_grace=0.05)
    t = FakeEvents()
    _wire_presence(t, "smallwebrtc", teardown, call, _log)
    await t.handlers["on_client_connected"](t, {"id": "pc-1"})
    await asyncio.sleep(0.1)
    assert call.on_line and greet.count == 0  # on the line; greets once ready
    await call.client_ready()
    assert greet.count == 1
    teardown._cancel_timer()
    call.stop()


def test_shipped_pipelines_gate_their_audio():
    from pipecat.processors.frame_processor import FrameProcessor

    from bot.pipelines import live, loopback

    class FakeTransport:
        def __init__(self):
            self._in, self._out = FrameProcessor(), FrameProcessor()

        def input(self):
            return self._in

        def output(self):
            return self._out

    lb = loopback.build(FakeTransport())
    assert len(lb.gates) == 1 and all(isinstance(g, AudioGate) for g in lb.gates)
    lv = live.build(FakeTransport())  # conftest provides offline model keys
    assert len(lv.gates) == 2 and all(isinstance(g, AudioGate) for g in lv.gates)
    assert lv.on_ready is not None


async def test_audio_gate_in_a_running_pipeline():
    from pipecat.tests.utils import run_test

    gate = AudioGate()
    gate.close()
    audio = dict(audio=b"\x00\x00" * 160, sample_rate=16000, num_channels=1)
    down, _ = await run_test(
        gate,
        frames_to_send=[InputAudioRawFrame(**audio), OutputAudioRawFrame(**audio), TextFrame(text="hi")],
        expected_down_frames=[TextFrame],
    )
    assert [type(f) for f in down] == [TextFrame]


class FakeLiveKitTransport(FakeEvents):
    def __init__(self):
        super().__init__()
        self.pushed = []
        outer = self

        class Input:
            async def push_frame(self, frame):
                outer.pushed.append(frame)

        self._input = Input()

    def input(self):
        return self._input


async def test_livekit_human_already_in_the_room_counts_as_the_first_join():
    # The phone beat the starting bot into the room: only on_first_participant_joined fires.
    from pipecat.frames.frames import ClientConnectedFrame

    call, teardown, _, greet, _ = _make()
    t = FakeLiveKitTransport()
    _wire_presence(t, "livekit", teardown, call, _log)
    await t.handlers["on_first_participant_joined"](t, "user-1")
    assert greet.count == 1
    assert [type(f) for f in t.pushed] == [ClientConnectedFrame]  # starts the tone agent too
    # Its later leave still starts the grace timer (the join was counted).
    teardown.human_left("user-1")
    assert teardown._timer is not None
    teardown._cancel_timer()


async def test_livekit_late_join_fires_both_events_but_greets_once():
    call, teardown, _, greet, _ = _make()
    t = FakeLiveKitTransport()
    _wire_presence(t, "livekit", teardown, call, _log)
    await t.handlers["on_participant_connected"](t, "user-1")
    await t.handlers["on_first_participant_joined"](t, "user-1")
    assert greet.count == 1
    assert t.pushed == []  # Pipecat already pushed its own ClientConnectedFrame


async def test_client_ready_answers_a_ring_bot_that_does_not_await():
    call, _, _, greet, _ = _make(deadline=60)
    await call.client_ready()
    assert call.answered
    assert greet.count == 1


# --- cancel: the bot is the authority on whether the call was answered ---


async def _cancel_line(call):
    replies = []

    async def lines():
        yield "cancel"

    await _read_control(lines(), call, _log, replies.append)
    return replies


async def test_cancel_ends_a_bot_that_has_not_seen_the_answer():
    call, _, worker, _, _ = _media_ring()
    assert await _cancel_line(call) == [True]
    assert worker.cancelled == 1
    call.stop()


async def test_cancel_is_refused_once_the_bot_saw_call_connected():
    call, _, worker, _, _ = _media_ring()
    await call.handle("call-connected")
    assert await _cancel_line(call) == [False]
    assert worker.cancelled == 0


async def test_cancel_is_refused_for_a_ring_bot_the_human_already_joined():
    # preconnect: credentials -- the join IS the answer.
    call, teardown, worker, _, _ = _make(deadline=60)
    t = FakeEvents()
    _wire_presence(t, "daily", teardown, call, _log)
    await t.handlers["on_participant_joined"](t, {"id": "p1"})
    assert await _cancel_line(call) == [False]
    assert worker.cancelled == 0


async def test_cancel_line_without_a_reply_channel_still_decides():
    call, _, worker, _, _ = _media_ring()

    async def lines():
        yield "cancel"

    await _read_control(lines(), call, _log)
    assert worker.cancelled == 1
    call.stop()


def test_the_verdict_goes_to_stdout_behind_the_control_prefix(capsys):
    reply_on_stdout(True)
    reply_on_stdout(False)
    assert capsys.readouterr().out == (
        f"{CONTROL_REPLY_PREFIX}cancel ended\n{CONTROL_REPLY_PREFIX}cancel refused\n"
    )


# --- the answered receipt only starts the fallback wait for call-connected ---


async def _receipt_line(call):
    async def lines():
        yield "answered"

    await _read_control(lines(), call, _log)


async def test_the_answered_receipt_waits_out_a_grace_for_call_connected():
    # The receipt is sent at answer, before the app's audio is up; releasing the
    # greeting on it would play into audio that may not be there yet.
    call, _, worker, greet, gates = _media_ring(connected_grace=0.1)
    await call.client_ready()
    await _receipt_line(call)
    assert call.answered and not call.on_line and greet.count == 0
    assert not any(g.is_open for g in gates)
    await asyncio.sleep(0.2)
    assert call.on_line and greet.count == 1
    assert all(g.is_open for g in gates)
    assert worker.cancelled == 0
    call.stop()


async def test_call_connected_inside_the_grace_releases_the_bot_once():
    call, _, _, greet, gates = _media_ring(connected_grace=0.1)
    await call.client_ready()
    await _receipt_line(call)
    await call.handle("call-connected")
    assert call.on_line and greet.count == 1
    await asyncio.sleep(0.2)
    assert greet.count == 1
    assert all(g.is_open for g in gates)
    call.stop()


async def test_the_receipt_stops_the_ring_deadline_during_the_grace():
    call, _, worker, _, _ = _make(
        await_connected=True, joins_before_answer=True, deadline=0.05, connected_grace=0.2
    )
    call.start()
    await call.human_joined("phone")
    await _receipt_line(call)
    await asyncio.sleep(0.12)
    assert worker.cancelled == 0
    await asyncio.sleep(0.2)
    assert call.on_line
    call.stop()


async def test_a_pending_receipt_blocks_a_cancel():
    call, _, worker, _, _ = _media_ring(connected_grace=1)
    await _receipt_line(call)
    replies = []

    async def lines():
        yield "cancel"

    await _read_control(lines(), call, _log, replies.append)
    assert replies == [False] and worker.cancelled == 0
    call.stop()


async def test_stopping_the_bot_drops_a_pending_fallback():
    call, _, _, greet, _ = _media_ring(connected_grace=0.05)
    await call.client_ready()
    await _receipt_line(call)
    call.stop()
    await asyncio.sleep(0.15)
    assert greet.count == 0 and not call.on_line


async def test_the_receipt_grace_starts_only_once_the_device_is_in_the_room():
    # The receipt is sent at the answer, often before the app has (re)joined: the
    # grace is counted from the later of the receipt and the device's join.
    call, _, _, greet, gates = _media_ring(connected_grace=0.1)
    await _receipt_line(call)
    await asyncio.sleep(0.2)
    assert not call.on_line and greet.count == 0  # nobody in the room yet
    await call.human_joined("phone")
    await asyncio.sleep(0.05)
    assert not call.on_line  # a full grace from the join, not from the receipt
    await call.client_ready()
    await asyncio.sleep(0.1)
    assert call.on_line and greet.count == 1
    assert all(g.is_open for g in gates)
    call.stop()


async def test_call_connected_after_a_late_join_still_wins_the_grace():
    call, _, _, greet, _ = _media_ring(connected_grace=0.1)
    await _receipt_line(call)
    await call.human_joined("phone")
    await call.client_ready()
    await call.handle("call-connected")
    assert call.on_line and greet.count == 1
    await asyncio.sleep(0.2)
    assert greet.count == 1
    call.stop()


async def test_the_device_leaving_stops_the_grace_and_its_return_restarts_it():
    call, _, _, greet, _ = _media_ring(connected_grace=0.1)
    await call.human_joined("phone-1")
    await call.client_ready()
    await _receipt_line(call)
    await asyncio.sleep(0.05)
    call.human_left("phone-1")
    await asyncio.sleep(0.1)
    assert not call.on_line  # the grace never ran out with the device there
    await call.human_joined("phone-2")
    await asyncio.sleep(0.05)
    assert not call.on_line  # restarted in full
    await asyncio.sleep(0.1)
    assert call.on_line and greet.count == 1
    call.stop()


async def test_a_reconnect_that_joins_before_the_old_participant_leaves_keeps_the_grace():
    call, _, _, _, _ = _media_ring(connected_grace=0.1)
    await call.human_joined("phone-1")
    await _receipt_line(call)
    await call.human_joined("phone-2")
    call.human_left("phone-1")
    await asyncio.sleep(0.15)
    assert call.on_line
    call.stop()


async def test_a_cancel_after_the_receipt_is_refused_while_the_device_is_away():
    call, _, worker, _, _ = _media_ring(connected_grace=0.1)
    await call.human_joined("phone")
    await _receipt_line(call)
    call.human_left("phone")
    assert await call.cancel() is False
    assert worker.cancelled == 0
    call.stop()


async def test_daily_and_livekit_leaves_reach_the_fallback_wait():
    for transport_type, join, leave, join_args, leave_args in (
        ("daily", "on_participant_joined", "on_participant_left", ({"id": "p1"},), ({"id": "p1"}, "left")),
        ("livekit", "on_participant_connected", "on_participant_left", ("p1",), ("p1", "left")),
    ):
        call, teardown, _, _, _ = _media_ring(connected_grace=0.05)
        t = FakeLiveKitTransport() if transport_type == "livekit" else FakeEvents()
        _wire_presence(t, transport_type, teardown, call, _log)
        await t.handlers[join](t, *join_args)
        await _receipt_line(call)
        await t.handlers[leave](t, *leave_args)
        await asyncio.sleep(0.1)
        assert not call.on_line, transport_type
        teardown._cancel_timer()
        call.stop()


def test_the_call_connected_grace_is_a_setting_of_at_least_five_seconds():
    # Longer than the app's own sequence after it joins (its minimum connecting
    # time and its "Connected"); the push contract's floor is 5 seconds.
    import pytest
    from pydantic import ValidationError

    from app.config import Settings, settings

    assert settings.call_connected_grace_secs >= 5
    assert Settings().call_connected_grace_secs == 10
    for bad in (4, 0, -1):
        with pytest.raises(ValidationError):
            Settings(call_connected_grace_secs=bad)
    assert Settings(call_connected_grace_secs=8).call_connected_grace_secs == 8
