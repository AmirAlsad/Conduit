"""Call-control signals from the device and the ring deadline.

The Conduit app sends RTVI client-messages beside ``end-call``
(``{"label":"rtvi-ai","type":"client-message","data":{"t":…}}``):

- ``call-answered``: the user answered a ring this bot was dispatched for. A bot
  dispatched with ``--await-answer`` (the app joins while the phone still rings)
  produces no audio and does not greet until it hears this. The ring's
  ``answered`` receipt, relayed by the dispatcher, counts too.
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
        log,
    ):
        self._teardown = teardown
        self._greet = greet
        self._gates = tuple(gates)
        self._awaiting = await_answer
        self._deadline_secs = ring_deadline_secs
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

    # --- readiness and presence ---

    async def client_ready(self) -> None:
        """The client can hear the bot: RTVI client-ready (Daily, SmallWebRTC), or
        the first human join on LiveKit, whose app sends no client-ready."""
        if not self._awaiting:
            # As before: every client-ready greets.
            await self._run_greet()
            return
        self._ready = True
        await self._maybe_greet()

    async def human_joined(self) -> bool:
        """A human joined. Returns True for the first join of this bot."""
        first = not self._joined
        self._joined = True
        if not self._awaiting:
            await self.answer("join")
        return first

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
