"""Call-control signals from the device and the ring deadline.

The Conduit app sends RTVI client-messages beside ``end-call``
(``{"label":"rtvi-ai","type":"client-message","data":{"t":…}}``):

- ``call-answered``: the user answered a ring this bot was dispatched for. A bot
  dispatched with ``--await-answer`` (the app joins while the phone still rings)
  produces no audio and does not greet until it hears this. The ring's
  ``answered`` receipt, relayed by the dispatcher, is only a fallback for a lost
  ``call-answered``: the app sends it at the moment of answer, before its audio is
  up and often before it has (re)joined, and ``call-answered`` once it is. So the
  receipt releases the bot only if ``call-answered`` has not come
  ``receipt_grace_secs`` (5 or more, the push contract's floor) after both the
  receipt and the device being in the room, whichever is later. The device
  leaving stops that wait, and its return starts it again in full.
- ``call-held`` / ``call-resumed``: the call went on hold (e.g. a cellular call)
  and back. Held: the bot is interrupted, hears nothing and says nothing, and a
  human leaving gets the longer held grace window.

A ring bot (``--ring-deadline``) ends if no answer arrives in time. Without
``--await-answer`` the human joining also counts as the answer, because the app
only joins such a ring after the user answered.
"""

from __future__ import annotations

import asyncio
from collections.abc import Awaitable, Callable, Sequence

from pipecat.frames.frames import InputAudioRawFrame, OutputAudioRawFrame
from pipecat.processors.frame_processor import FrameDirection, FrameProcessor

from app.obs import event

CALL_ANSWERED = "call-answered"
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
        await_answer: bool = False,
        ring_deadline_secs: float | None = None,
        receipt_grace_secs: float = 0.0,
        log,
    ):
        self._teardown = teardown
        self._greet = greet
        self._gates = tuple(gates)
        self._awaiting = await_answer
        self._deadline_secs = ring_deadline_secs
        self._receipt_grace_secs = receipt_grace_secs
        self._receipt_seen = False
        self._receipt_task: asyncio.Task | None = None
        # The device's participants in the room (a reconnect can join a new one
        # before the old one leaves).
        self._present: set[str] = set()
        self._log = log
        # A bot not dispatched for a ring was answered before it existed.
        self._answered = not (await_answer or ring_deadline_secs is not None)
        self._ready = False
        self._greeted = False
        self._held = False
        self._joined = False
        self._deadline_task: asyncio.Task | None = None
        if await_answer:
            for gate in self._gates:
                gate.close()

    @property
    def answered(self) -> bool:
        return self._answered

    @property
    def held(self) -> bool:
        return self._held

    def start(self) -> None:
        if self._deadline_secs is not None and not self._answered:
            self._deadline_task = asyncio.create_task(self._ring_deadline())

    def stop(self) -> None:
        if self._deadline_task and not self._deadline_task.done():
            self._deadline_task.cancel()
        self._deadline_task = None
        self._drop_receipt_release()

    # --- readiness and presence ---

    async def client_ready(self) -> None:
        """The client can hear the bot: RTVI client-ready (Daily, SmallWebRTC), or
        the first human join on LiveKit, whose app sends no client-ready."""
        if not self._awaiting:
            # Without await-answer the app connects only after the answer.
            await self.answer("ready")
            # As before: every client-ready greets.
            await self._run_greet()
            return
        self._ready = True
        if not self._present:
            # A ready client is in the room, even where no join was reported.
            self._present.add(READY_CLIENT)
        await self._arm_receipt_release()
        await self._maybe_greet()

    async def human_joined(self, participant_id: str = "human") -> bool:
        """A human joined. Returns True for the first join of this bot."""
        first = not self._joined
        self._joined = True
        self._present.add(participant_id)
        if not self._awaiting:
            await self.answer("join")
        await self._arm_receipt_release()
        return first

    def human_left(self, participant_id: str = "human") -> None:
        """A human left. With nobody left in the room, a pending receipt release
        stops; the next join starts its wait again in full."""
        self._present.discard(participant_id)
        self._present.discard(READY_CLIENT)
        if not self._present:
            self._drop_receipt_release()

    # --- signals ---

    async def handle(self, signal: str) -> bool:
        """Apply one call-control signal (the client-message ``t``). False if it
        isn't one."""
        if signal == CALL_ANSWERED:
            await self.answer("signal")
        elif signal == CALL_HELD:
            await self.hold()
        elif signal == CALL_RESUMED:
            await self.resume()
        else:
            return False
        return True

    async def answer(self, via: str) -> None:
        if self._answered:
            return
        self._answered = True
        self.stop()
        event(self._log, "bot.call_answered", via=via)
        if self._awaiting:
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
        deadline no longer applies; the bot is released only if ``call-answered``
        has not come by the end of the grace, counted from the receipt or the
        device being in the room, whichever is later."""
        if self._answered or self._receipt_seen:
            return
        self._receipt_seen = True
        if self._deadline_task and not self._deadline_task.done():
            self._deadline_task.cancel()
        self._deadline_task = None
        event(
            self._log,
            "bot.receipt_answered",
            grace_secs=self._receipt_grace_secs,
            device_in_room=bool(self._present),
        )
        await self._arm_receipt_release()

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
        if self._answered:
            self._open_gates()
        event(self._log, "bot.call_resumed")

    # --- internals ---

    async def _arm_receipt_release(self) -> None:
        """Start the receipt's grace once both it and the device are there."""
        if self._answered or not self._receipt_seen or not self._present:
            return
        if self._receipt_task is not None:
            return
        if self._receipt_grace_secs <= 0:
            await self.answer("receipt")
            return
        self._receipt_task = asyncio.create_task(self._release_after_grace())

    def _drop_receipt_release(self) -> None:
        task, self._receipt_task = self._receipt_task, None
        if task is not None and not task.done() and task is not asyncio.current_task():
            task.cancel()

    async def _release_after_grace(self) -> None:
        try:
            await asyncio.sleep(self._receipt_grace_secs)
        except asyncio.CancelledError:
            return
        await self.answer("receipt")

    def _open_gates(self) -> None:
        for gate in self._gates:
            gate.open()

    async def _maybe_greet(self) -> None:
        if self._answered and self._ready and not self._greeted:
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
