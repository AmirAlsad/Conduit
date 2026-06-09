"""Teardown / reconnection policy (design §2.5).

The one place Pipecat's defaults work *against* this client. The common pattern
cancels the pipeline the instant the human leaves. That breaks the headline
reconnection feature: the iOS client drops media in tunnels/dead-zones and
reconnects with backoff while CallKit still shows the call up. If the bot exits
the moment the connection drops, the client reconnects into an empty room.

Policy:
- On the human leaving, do NOT exit. Start a human-absent grace timer; tear down
  only if no human has rejoined when it expires. While the bot stays, the room is
  non-empty (won't auto-close) and a rejoining client resumes mid-conversation.
- A real hangup and a dropped connection look identical at the transport layer.
  An explicit end signal (RTVI ``end-call`` message, or ``/admin/disconnect``)
  ends the call at once and reserves the grace window for genuine drops.
"""

from __future__ import annotations

import asyncio

from app.obs import event


class TeardownController:
    """Tracks human presence and tears the worker down on a real end or after the
    grace window elapses with the room empty of humans."""

    def __init__(self, worker, grace_secs: float, log):
        self._worker = worker
        self._grace = grace_secs
        self._log = log
        self._humans: set[str] = set()
        self._timer: asyncio.Task | None = None
        self._ended = False

    # --- presence signals (wired per-transport in runtime.run_bot) ---

    def human_joined(self, participant_id: str) -> None:
        first = not self._humans
        self._humans.add(participant_id)
        # A rejoin within the grace window cancels teardown and resumes the call.
        self._cancel_timer()
        event(
            self._log,
            "teardown.human_joined" if not first else "teardown.first_human",
            pid=participant_id,
            humans=len(self._humans),
        )

    def human_left(self, participant_id: str) -> None:
        self._humans.discard(participant_id)
        event(self._log, "teardown.human_left", pid=participant_id, humans=len(self._humans))
        if not self._humans and not self._ended:
            self._start_timer()

    # --- explicit end (real hangup / admin) ---

    async def end_now(self, reason: str) -> None:
        if self._ended:
            return
        self._ended = True
        self._cancel_timer()
        event(self._log, "teardown.end_now", reason=reason)
        await self._worker.cancel()

    # --- internals ---

    def _start_timer(self) -> None:
        self._cancel_timer()
        event(self._log, "teardown.grace_started", grace_secs=self._grace)
        self._timer = asyncio.create_task(self._expire())

    def _cancel_timer(self) -> None:
        if self._timer and not self._timer.done():
            self._timer.cancel()
            event(self._log, "teardown.grace_cancelled")
        self._timer = None

    async def _expire(self) -> None:
        try:
            await asyncio.sleep(self._grace)
        except asyncio.CancelledError:
            return
        if self._humans or self._ended:
            return
        self._ended = True
        event(self._log, "teardown.grace_expired")
        await self._worker.cancel()
