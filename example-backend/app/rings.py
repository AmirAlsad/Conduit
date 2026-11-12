"""Ring tracker: what the engine knows about each ring it sent, keyed by call_id.

It links a ring to the bot dispatched for it (inline rings at ring time, pairing
rings when the app fetches credentials during the ring), records the ring's
receipt, and backs POST /admin/ring/{agent_id}/cancel.

In memory and process-local, like active bots: a ring lasts about a minute, and a
restarted dispatcher has no bots to steer anyway. Entries expire after an hour.
"""

from __future__ import annotations

import time
from collections.abc import Callable
from dataclasses import dataclass

from app.config import settings

_TTL_SECS = 60 * 60
# The app clamps a pushed ring_timeout to at least this many seconds.
_MIN_RING_TIMEOUT_SECS = 10


@dataclass
class TrackedRing:
    call_id: str
    agent_id: str  # the engine's agent id (the route's), not the app's UUID
    mode: str  # "pairing" | "inline"
    preconnect: str | None = None
    ring_timeout: int | None = None
    # The bot dispatched for this ring, once there is one.
    room_key: str | None = None
    transport: str | None = None
    # True when that bot was dispatched with the ring flags (deadline + control
    # channel): receipts then steer it.
    ring_bot: bool = False
    awaits_answer: bool = False
    status: str | None = None  # the ring's receipt, once it arrives
    canceled: bool = False
    created_at: float = 0.0


def ring_deadline_secs(ring_timeout: int | None) -> float:
    """How long a ring bot waits for an answer before it ends."""
    timeout = max(_MIN_RING_TIMEOUT_SECS, ring_timeout or settings.ring_timeout_secs)
    return timeout + settings.ring_deadline_margin_secs


def ring_bot_flags(*, ring_timeout: int | None, await_answer: bool) -> list[str]:
    """argv flags for a bot dispatched for a ring (see bot/bot.py)."""
    flags = ["--ring-deadline", f"{ring_deadline_secs(ring_timeout):g}"]
    if await_answer:
        flags.append("--await-answer")
    return flags


class RingTracker:
    def __init__(self, clock: Callable[[], float] = time.monotonic) -> None:
        self._clock = clock
        self._rings: dict[str, TrackedRing] = {}

    def add(self, ring: TrackedRing) -> TrackedRing:
        self._prune()
        ring.created_at = self._clock()
        self._rings[ring.call_id] = ring
        return ring

    def get(self, call_id: str) -> TrackedRing | None:
        self._prune()
        return self._rings.get(call_id)

    def discard(self, call_id: str) -> None:
        self._rings.pop(call_id, None)

    def attach_bot(
        self,
        call_id: str,
        agent_id: str,
        *,
        room_key: str,
        transport: str,
        awaits_answer: bool,
    ) -> TrackedRing | None:
        """Record the ring bot dispatched when the app paired during the ring. A
        call_id the tracker doesn't know (e.g. sent before a restart) is adopted so
        its receipt can still steer the bot; one owned by another agent is left alone."""
        ring = self.get(call_id)
        if ring is None:
            ring = self.add(TrackedRing(call_id=call_id, agent_id=agent_id, mode="pairing"))
        elif ring.agent_id != agent_id:
            return None
        ring.room_key = room_key
        ring.transport = transport
        ring.ring_bot = True
        ring.awaits_answer = awaits_answer
        return ring

    def _prune(self) -> None:
        cutoff = self._clock() - _TTL_SECS
        self._rings = {k: r for k, r in self._rings.items() if r.created_at > cutoff}
