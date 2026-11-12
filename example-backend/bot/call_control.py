"""Call-control signals from the device, when the agent may speak, and the ring
deadline.

The Conduit app sends RTVI client-messages beside ``end-call``
(``{"label":"rtvi-ai","type":"client-message","data":{"t":…}}``):

- ``call-connected``: the user is on the line and can hear the agent. The app
  sends it on every call once the call is connected, iOS has activated its audio,
  it is not held, and the app's own "Connected" has played; again after every
  reconnect. A bot started for a client that said it sends it (``call_signals``
  in its pairing request or push registration, ``--await-connected`` here)
  produces no audio and does not greet until it arrives. It is the one moment to
  start speaking; a client that never said so is greeted when it is ready, as
  before. As a fallback for a lost one, once the bot knows the user answered and
  the device is in the room, whichever is later, it releases itself after
  ``connected_grace_secs``; the device leaving stops that wait, and its return
  starts it again in full.
- ``call-held`` / ``call-resumed``: the call went on hold (e.g. a cellular call)
  and back. Held: the bot is interrupted, hears nothing and says nothing, and a
  human leaving gets the longer held grace window. ``call-connected`` is never
  sent while held, so it also says the call is not held.

A ring bot (``--ring-deadline``) ends if no answer arrives in time. The answer is
``call-connected``, the ring's ``answered`` receipt (relayed by the dispatcher),
or, unless the device joins before the answer (``--joins-before-answer``, a
``"media"`` ring), the device joining. The receipt is sent at the moment of
answer, before the app's audio is up, so it starts the fallback wait; it never
releases the bot by itself.
"""

from __future__ import annotations

import asyncio
from collections.abc import Awaitable, Callable, Sequence

from pipecat.frames.frames import InputAudioRawFrame, OutputAudioRawFrame
from pipecat.processors.frame_processor import FrameDirection, FrameProcessor

from app.obs import event

CALL_CONNECTED = "call-connected"
CALL_HELD = "call-held"
CALL_RESUMED = "call-resumed"

# Stands for a client that reported ready on a transport that reports no join.
READY_CLIENT = "ready-client"


class AudioGate(FrameProcessor):
    """Passes everything while open; while closed, drops audio (the caller's on
    its way in, the bot's on its way out). Pipelines place one after the input
    transport and one before the output transport."""

    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self._open = True

    @property
    def is_open(self) -> bool:
        return self._open

    def open(self) -> None:
        self._open = True

    def close(self) -> None:
        self._open = False

    async def interrupt(self) -> None:
        """Cut off whatever the bot is saying (both directions from here)."""
        await self.broadcast_interruption()

    async def process_frame(self, frame, direction: FrameDirection):
        await super().process_frame(frame, direction)
        if not self._open and isinstance(frame, (InputAudioRawFrame, OutputAudioRawFrame)):
            return
        await self.push_frame(frame, direction)


class CallControl:
    def __init__(
        self,
        *,
        teardown,
        greet: Callable[[], Awaitable[None]] | None,
        gates: Sequence[AudioGate] = (),
        await_connected: bool = False,
        joins_before_answer: bool = False,
        ring_deadline_secs: float | None = None,
        connected_grace_secs: float = 0.0,
        log,
    ):
        self._teardown = teardown
        self._greet = greet
        self._gates = tuple(gates)
        # A device in the room before the answer must not hear the bot, even from a
        # client that never said it sends call-connected (the fallback releases it).
        self._awaiting = await_connected or joins_before_answer
        self._joins_before_answer = joins_before_answer
        self._deadline_secs = ring_deadline_secs
        self._grace_secs = connected_grace_secs
        self._receipt_seen = False
        self._fallback_task: asyncio.Task | None = None
        # The device's participants in the room (a reconnect can join a new one
        # before the old one leaves).
        self._present: set[str] = set()
        self._log = log
        # Whether the bot knows the user answered: a bot not dispatched for a ring
        # was answered before it existed.
        self._answered = not (joins_before_answer or ring_deadline_secs is not None)
        # Whether the user is on the line, so the bot may speak.
        self._on_line = not self._awaiting
        self._ready = False
        self._greeted = False
        self._held = False
        self._joined = False
        self._deadline_task: asyncio.Task | None = None
        if self._awaiting:
            for gate in self._gates:
                gate.close()

    @property
    def answered(self) -> bool:
        return self._answered

    @property
    def on_line(self) -> bool:
        return self._on_line

    @property
    def held(self) -> bool:
        return self._held

    def start(self) -> None:
        if self._deadline_secs is not None and not self._answered:
            self._deadline_task = asyncio.create_task(self._ring_deadline())

    def stop(self) -> None:
        self._cancel_deadline()
        self._drop_fallback()

    # --- readiness and presence ---

    async def client_ready(self) -> None:
        """The client can hear the bot: RTVI client-ready (Daily, SmallWebRTC), or
        the first human join on LiveKit, whose app sends no client-ready."""
        if not self._awaiting:
            # The app connects such a call only after the answer.
            await self._mark_answered("ready")
            # As before: every client-ready greets.
            await self._run_greet()
            return
        self._ready = True
        if not self._present:
            # A ready client is in the room, even where no join was reported.
            self._present.add(READY_CLIENT)
        if not self._joins_before_answer:
            await self._mark_answered("ready")
        await self._arm_fallback()
        await self._maybe_greet()

    async def human_joined(self, participant_id: str = "human") -> bool:
        """A human joined. Returns True for the first join of this bot."""
        first = not self._joined
        self._joined = True
        self._present.add(participant_id)
        if not self._joins_before_answer:
            await self._mark_answered("join")
        await self._arm_fallback()
        return first

    def human_left(self, participant_id: str = "human") -> None:
        """A human left. With nobody left in the room, a pending fallback release
        stops; the next join starts its wait again in full."""
        self._present.discard(participant_id)
        self._present.discard(READY_CLIENT)
        if not self._present:
            self._drop_fallback()

    # --- signals ---

    async def handle(self, signal: str) -> bool:
        """Apply one call-control signal (the client-message ``t``). False if it
        isn't one."""
        if signal == CALL_CONNECTED:
            await self.connected("signal")
        elif signal == CALL_HELD:
            await self.hold()
        elif signal == CALL_RESUMED:
            await self.resume()
        else:
            return False
        return True

    async def connected(self, via: str) -> None:
        """The user is on the line (``call-connected``, or the fallback). A repeat
        (every reconnect sends one) is the same call coming back: it greets no
        one again, but it does say the call is not held."""
        await self._mark_answered(via)
        if self._held and via == "signal":
            await self.resume()
        if self._on_line:
            return
        self._on_line = True
        if via == "signal":
            # The client says the user can hear the bot; the fallback still waits
            # for the client to be ready.
            self._ready = True
        self._drop_fallback()
        event(self._log, "bot.call_connected", via=via)
        if not self._held:
            self._open_gates()
        await self._maybe_greet()

    async def cancel(self, announce: Callable[[bool], None] | None = None) -> bool:
        """The dispatcher withdrew the ring. End the bot unless it has itself seen
        the call answered, and say which through ``announce`` before the (slow)
        teardown. An answer the bot has not seen yet loses the race; that window
        is the receipt's flight time."""
        ended = not (self._answered or self._receipt_seen)
        if announce is not None:
            announce(ended)
        if not ended:
            event(self._log, "bot.cancel_refused")
            return False
        self.stop()
        event(self._log, "bot.ring_canceled")
        await self._teardown.end_now("ring-canceled")
        return True

    async def receipt_answered(self) -> None:
        """The ring's ``answered`` receipt. The phone has answered, so the ring
        deadline no longer applies, and the fallback wait for ``call-connected``
        can start once the device is in the room."""
        if self._receipt_seen:
            return
        self._receipt_seen = True
        event(
            self._log,
            "bot.receipt_answered",
            grace_secs=self._grace_secs,
            device_in_room=bool(self._present),
        )
        await self._mark_answered("receipt")
        await self._arm_fallback()

    async def hold(self) -> None:
        if self._held:
            return
        self._held = True
        self._teardown.set_held(True)
        for gate in self._gates:
            gate.close()
        if self._gates:
            await self._gates[0].interrupt()
        event(self._log, "bot.call_held")

    async def resume(self) -> None:
        if not self._held:
            return
        self._held = False
        self._teardown.set_held(False)
        if self._on_line:
            self._open_gates()
        event(self._log, "bot.call_resumed")

    # --- internals ---

    async def _mark_answered(self, via: str) -> None:
        if self._answered:
            return
        self._answered = True
        self._cancel_deadline()
        event(self._log, "bot.call_answered", via=via)

    async def _arm_fallback(self) -> None:
        """Start the fallback wait once the user answered and the device is there."""
        if self._on_line or not self._answered or not self._present:
            return
        if self._fallback_task is not None:
            return
        if self._grace_secs <= 0:
            await self.connected("fallback")
            return
        self._fallback_task = asyncio.create_task(self._release_after_grace())

    def _drop_fallback(self) -> None:
        task, self._fallback_task = self._fallback_task, None
        if task is not None and not task.done() and task is not asyncio.current_task():
            task.cancel()

    def _cancel_deadline(self) -> None:
        task, self._deadline_task = self._deadline_task, None
        if task is not None and not task.done() and task is not asyncio.current_task():
            task.cancel()

    async def _release_after_grace(self) -> None:
        try:
            await asyncio.sleep(self._grace_secs)
        except asyncio.CancelledError:
            return
        self._fallback_task = None
        event(self._log, "bot.call_connected_missing", grace_secs=self._grace_secs)
        await self.connected("fallback")

    def _open_gates(self) -> None:
        for gate in self._gates:
            gate.open()

    async def _maybe_greet(self) -> None:
        if self._on_line and self._ready and not self._greeted:
            self._greeted = True
            await self._run_greet()

    async def _run_greet(self) -> None:
        if self._greet is not None:
            await self._greet()

    async def _ring_deadline(self) -> None:
        try:
            await asyncio.sleep(self._deadline_secs)
        except asyncio.CancelledError:
            return
        if not self._answered:
            event(self._log, "bot.ring_deadline", secs=self._deadline_secs)
            await self._teardown.end_now("ring-unanswered")
