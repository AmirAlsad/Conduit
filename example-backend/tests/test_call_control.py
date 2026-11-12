"""Bot-side call control: the await-answer mode, the ring deadline, hold/resume,
and how each transport's wiring delivers the signals (bot/call_control.py)."""

import asyncio
import json

from pipecat.frames.frames import (
    InputAudioRawFrame,
    OutputAudioRawFrame,
    TextFrame,
)
from pipecat.processors.frame_processor import FrameDirection

from app.obs import get_logger
from bot.call_control import AudioGate, CallControl
from bot.runtime import _read_control, _wire_presence, _wire_rtvi
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


def _make(*, await_answer=False, deadline=None, gates=None, grace=100.0):
    worker = FakeWorker()
    teardown = TeardownController(worker, grace_secs=grace, log=_log, held_grace_secs=0.3)
    greet = Greeter()
    gates = [FakeGate(), FakeGate()] if gates is None else gates
    call = CallControl(
        teardown=teardown,
        greet=greet,
        gates=gates,
        await_answer=await_answer,
        ring_deadline_secs=deadline,
        log=_log,
    )
    return call, teardown, worker, greet, gates


def _lk_wire(data_t):
    return json.dumps(
        {"id": "x1", "label": "rtvi-ai", "type": "client-message", "data": {"t": data_t}}
    ).encode()


# --- no ring: today's behaviour ---


async def test_without_a_ring_every_client_ready_greets_and_gates_stay_open():
    call, _, _, greet, gates = _make()
    assert call.answered
    await call.client_ready()
    await call.client_ready()
    assert greet.count == 2  # unchanged: each RTVI client-ready greets
    assert all(g.is_open for g in gates)


# --- await-answer (preconnect: media) ---


async def test_await_answer_is_silent_until_answered_then_greets_once():
    call, _, _, greet, gates = _make(await_answer=True, deadline=60)
    assert not any(g.is_open for g in gates)
    await call.client_ready()  # the phone joined while ringing
    assert greet.count == 0
    await call.handle("call-answered")
    assert call.answered
    assert all(g.is_open for g in gates)
    assert greet.count == 1
    # The app re-sends call-answered after every reconnect; no second greeting.
    await call.handle("call-answered")
    await call.client_ready()
    assert greet.count == 1
    call.stop()


async def test_await_answer_greets_at_ready_when_the_answer_came_first():
    # A 0.1 app ignores preconnect: its answered receipt arrives before it joins.
    call, _, _, greet, _ = _make(await_answer=True, deadline=60)
    await call.answer("receipt")
    assert greet.count == 0
    await call.client_ready()
    assert greet.count == 1
    call.stop()


async def test_await_answer_ignores_the_human_joining():
    call, _, _, greet, gates = _make(await_answer=True, deadline=60)
    assert await call.human_joined() is True
    assert await call.human_joined() is False
    assert not call.answered
    assert not any(g.is_open for g in gates)
    call.stop()


async def test_ring_deadline_ends_an_unanswered_bot():
    call, _, worker, greet, _ = _make(await_answer=True, deadline=0.05)
    call.start()
    await asyncio.sleep(0.15)
    assert worker.cancelled == 1
    assert greet.count == 0


async def test_answer_cancels_the_ring_deadline():
    call, _, worker, _, _ = _make(await_answer=True, deadline=0.05)
    call.start()
    await call.handle("call-answered")
    await asyncio.sleep(0.15)
    assert worker.cancelled == 0


async def test_ring_bot_without_await_takes_the_join_as_the_answer():
    # preconnect: credentials — the app joins only after the user answered.
    call, _, worker, _, gates = _make(deadline=0.05)
    assert all(g.is_open for g in gates)
    call.start()
    await call.human_joined()
    assert call.answered
    await asyncio.sleep(0.15)
    assert worker.cancelled == 0


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


async def test_answer_while_held_keeps_the_gates_closed():
    call, _, _, _, gates = _make(await_answer=True, deadline=60)
    await call.handle("call-held")
    await call.handle("call-answered")
    assert not any(g.is_open for g in gates)
    await call.handle("call-resumed")
    assert all(g.is_open for g in gates)
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


async def test_livekit_raw_call_answered_releases_an_awaiting_bot():
    call, teardown, worker, greet, gates = _make(await_answer=True, deadline=60)
    t = FakeEvents()
    _wire_presence(t, "livekit", teardown, call, _log)
    await t.handlers["on_participant_connected"](t, "user-1")  # joined while ringing
    assert greet.count == 0
    await t.handlers["on_data_received"](t, _lk_wire("call-answered"), "user-1")
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
    call, teardown, worker, greet, gates = _make(await_answer=True, deadline=60)
    t, rtvi = FakeEvents(), FakeEvents()
    _wire_presence(t, "daily", teardown, call, _log)
    _wire_rtvi(rtvi, teardown, call, "live", _log)
    await t.handlers["on_participant_joined"](t, {"id": "p1"})
    await rtvi.handlers["on_client_ready"](rtvi)
    assert greet.count == 0
    await rtvi.handlers["on_client_message"](rtvi, RtviMessage("call-answered"))
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
    call, _, _, greet, _ = _make(await_answer=True, deadline=60)
    await call.client_ready()

    async def lines():
        yield "noise"
        yield "answered"

    await _read_control(lines(), call, _log)
    assert call.answered
    assert greet.count == 1
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
