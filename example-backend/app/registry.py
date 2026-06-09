"""Registry: which rooms are agent-enabled (direct mode), and which rooms have an
active bot (idempotent dispatch).

Defined behind an interface so the persistent swap is config, not a refactor
(design §2.1). ⚠️ The in-memory implementation does NOT survive a restart/redeploy:
direct-mode rooms recorded at provision time are lost, so a webhook arriving after
a redeploy finds no mapping and dispatches nobody — the call connects to silence.
Wire a Postgres/Redis-backed Registry before relying on direct mode in production.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol, runtime_checkable

from app.obs import event, get_logger

_log = get_logger("registry")


@dataclass
class RoomRecord:
    room_key: str  # daily room name / livekit room name — the idempotency + webhook key
    agent_id: str
    transport: str
    # Daily needs the full room URL to dispatch a bot at webhook time (the webhook
    # only carries the room name). LiveKit reconstructs from room_key + LIVEKIT_URL.
    room_url: str | None = None


@runtime_checkable
class Registry(Protocol):
    async def enable_room(
        self, room_key: str, agent_id: str, transport: str, room_url: str | None = None
    ) -> None: ...
    async def get_room(self, room_key: str) -> RoomRecord | None: ...
    async def set_active_bot(self, room_key: str, pid: int) -> None: ...
    async def clear_active_bot(self, room_key: str) -> None: ...
    async def active_bot(self, room_key: str) -> int | None: ...


class InMemoryRegistry:
    """First-milestone store. See module docstring for the redeploy caveat."""

    # Sentinel pid meaning "spawn in flight" — set inside the dispatch lock before
    # the subprocess exists, so a racing webhook sees the room as already active.
    SPAWNING = -1

    def __init__(self) -> None:
        self._rooms: dict[str, RoomRecord] = {}
        self._active: dict[str, int] = {}

    async def enable_room(
        self, room_key: str, agent_id: str, transport: str, room_url: str | None = None
    ) -> None:
        self._rooms[room_key] = RoomRecord(room_key, agent_id, transport, room_url)
        event(
            _log,
            "registry.room_enabled",
            room=room_key,
            agent=agent_id,
            transport=transport,
            note="in-memory-only-not-redeploy-safe",
        )

    async def get_room(self, room_key: str) -> RoomRecord | None:
        return self._rooms.get(room_key)

    async def set_active_bot(self, room_key: str, pid: int) -> None:
        self._active[room_key] = pid

    async def clear_active_bot(self, room_key: str) -> None:
        self._active.pop(room_key, None)

    async def active_bot(self, room_key: str) -> int | None:
        return self._active.get(room_key)
