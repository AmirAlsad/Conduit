"""Ring tracker: what the engine knows about each ring it sent, keyed by call_id.

It links a ring to the bot dispatched for it (at ring time for inline rings and
for pre-connected pairing rings, whose prepared room the app's credential request
during the ring then takes; otherwise when the app fetches credentials during the
ring), records the ring's receipt, and backs POST /admin/ring/{agent_id}/cancel.

In memory and process-local, like active bots: a ring lasts about a minute, and a
restarted dispatcher has no bots to steer anyway. Entries expire after an hour.
"""

from __future__ import annotations

import asyncio
import time
from collections.abc import Callable
from dataclasses import dataclass, field

from app.config import settings
from app.models import ConnectionPayload

_TTL_SECS = 60 * 60
# The app clamps a pushed ring_timeout to at least this many seconds.
_MIN_RING_TIMEOUT_SECS = 10
# The cancel endpoint's 409 reason when the device doesn't list the "cancel"
# push feature and the ring can't be withdrawn in band.
CANCEL_UNSUPPORTED = "cancel unsupported by device"
# The 409 reason when a ring is already over: a cancel, or a pairing request
# made for it, came too late.
RING_ENDED = "ring ended"
# ...and when the ring's bot has itself seen the call answered, before the
# answered receipt reached the engine.
CANCEL_ANSWERED = "ring answered"

# The ring-bot control protocol (dispatcher stdin -> bot, bot stdout -> dispatcher).
# A "cancel" line asks the bot to end unless it knows the call was answered; the
# bot's one-line verdict comes back on stdout behind this prefix.
CONTROL_REPLY_PREFIX = "@conduit-control "
CANCEL_ENDED = "ended"
CANCEL_REFUSED = "refused"
# A bot dispatched with --report-joined writes this line (behind the prefix) once
# its transport has joined the room: the ring's push waits for it.
CONTROL_JOINED = "joined"


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
    # The device joins the bot's room before the user answers ("media").
    joins_before_answer: bool = False
    # A pairing ring's room and bot, prepared at ring time, until the app's first
    # credential request for the ring takes them (or they are given up).
    prepared: ConnectionPayload | None = None
    # Whether that bot was dispatched with --await-connected.
    prepared_await_connected: bool = False
    # Tracked, but its push has not gone out yet (the engine is waiting for the bot).
    awaiting_push: bool = False
    status: str | None = None  # the ring's receipt, once it arrives
    canceled: bool = False
    # Set by the first receipt and by our cancel: wakes a ring still waiting to push.
    ended: asyncio.Event = field(default_factory=asyncio.Event, repr=False, compare=False)
    created_at: float = 0.0


def ring_deadline_secs(ring_timeout: int | None) -> float:
    """How long a ring bot waits for an answer before it ends."""
    timeout = max(_MIN_RING_TIMEOUT_SECS, ring_timeout or settings.ring_timeout_secs)
    return timeout + settings.ring_deadline_margin_secs


def ring_bot_flags(
    *, ring_timeout: int | None, joins_before_answer: bool, push_wait_secs: float = 0.0
) -> list[str]:
    """argv flags for a bot dispatched for a ring (see bot/bot.py).
    ``push_wait_secs``: the longest the ring's push may wait for this bot to join.
    The bot counts its deadline from its own start, so the wait is added to keep
    the full ring after the push."""
    deadline = ring_deadline_secs(ring_timeout) + push_wait_secs
    flags = ["--ring-deadline", f"{deadline:g}"]
    if joins_before_answer:
        flags.append("--joins-before-answer")
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
        joins_before_answer: bool,
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
        ring.joins_before_answer = joins_before_answer
        return ring

    def _prune(self) -> None:
        cutoff = self._clock() - _TTL_SECS
        self._rings = {k: r for k, r in self._rings.items() if r.created_at > cutoff}
