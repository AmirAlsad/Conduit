"""Registry: which rooms are agent-enabled (direct mode), which rooms have an
active bot (idempotent dispatch), and which devices registered a VoIP push token
(inbound calls).

SQLite-backed. Rooms and VoIP tokens persist across restarts when
``REGISTRY_DB_PATH`` points at durable storage (e.g. a mounted volume); with the
default cwd file or an ephemeral filesystem, a redeploy loses them — direct-mode
dispatch until re-provisioned, inbound rings until the app's next launch
re-registers its token. Active-bot state is deliberately in-memory only: pids are
process-local (bots die with the dispatcher), and persisting the SPAWNING sentinel
would permanently block a room after a crash mid-spawn.

Single-process only, like the dispatcher itself: SQLite here does not make
multi-replica deployments safe (dispatch idempotency still relies on one event
loop). Keep one replica.
"""

from __future__ import annotations

import sqlite3
import threading
from dataclasses import dataclass
from datetime import datetime, timezone
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


@dataclass
class VoipRegistration:
    backend_agent_id: str  # which engine agent the device registered with ("live", …)
    app_agent_id: str  # the app's UUID for that agent — goes in the push payload
    voip_token: str  # hex APNs VoIP device token
    platform: str
    bundle_id: str  # apns-topic = bundle_id + ".voip"


@runtime_checkable
class Registry(Protocol):
    async def enable_room(
        self, room_key: str, agent_id: str, transport: str, room_url: str | None = None
    ) -> None: ...
    async def get_room(self, room_key: str) -> RoomRecord | None: ...
    async def set_active_bot(self, room_key: str, pid: int) -> None: ...
    async def clear_active_bot(self, room_key: str) -> None: ...
    async def active_bot(self, room_key: str) -> int | None: ...
    async def register_voip(self, registration: VoipRegistration) -> None: ...
    async def get_voip(self, backend_agent_id: str) -> VoipRegistration | None: ...
    async def delete_voip(self, backend_agent_id: str) -> None: ...


class SQLiteRegistry:
    """See module docstring for the durability and single-replica caveats."""

    def __init__(self, db_path: str = "registry.db") -> None:
        # One persistent connection: required for ":memory:" (a new connection would
        # get a fresh empty db), and each statement is sub-millisecond so running
        # inline on the event loop is fine. The lock covers cross-thread callers
        # (e.g. TestClient's portal thread).
        self._conn = sqlite3.connect(db_path, check_same_thread=False)
        self._lock = threading.Lock()
        self._active: dict[str, int] = {}
        with self._lock:
            self._conn.execute("PRAGMA journal_mode=WAL")
            self._conn.execute("PRAGMA busy_timeout=5000")
            self._conn.execute(
                """CREATE TABLE IF NOT EXISTS rooms (
                    room_key   TEXT PRIMARY KEY,
                    agent_id   TEXT NOT NULL,
                    transport  TEXT NOT NULL,
                    room_url   TEXT,
                    created_at TEXT NOT NULL
                )"""
            )
            self._conn.execute(
                """CREATE TABLE IF NOT EXISTS voip_tokens (
                    backend_agent_id TEXT PRIMARY KEY,
                    app_agent_id     TEXT NOT NULL,
                    voip_token       TEXT NOT NULL,
                    platform         TEXT NOT NULL,
                    bundle_id        TEXT NOT NULL,
                    updated_at       TEXT NOT NULL
                )"""
            )
            self._conn.commit()

    def close(self) -> None:
        with self._lock:
            self._conn.close()

    # -- rooms (direct mode) ---------------------------------------------------

    def _get_room(self, room_key: str) -> RoomRecord | None:
        with self._lock:
            row = self._conn.execute(
                "SELECT room_key, agent_id, transport, room_url FROM rooms WHERE room_key = ?",
                (room_key,),
            ).fetchone()
        return RoomRecord(*row) if row else None

    async def enable_room(
        self, room_key: str, agent_id: str, transport: str, room_url: str | None = None
    ) -> None:
        with self._lock:
            self._conn.execute(
                "INSERT OR REPLACE INTO rooms VALUES (?, ?, ?, ?, ?)",
                (room_key, agent_id, transport, room_url, _now()),
            )
            self._conn.commit()
        event(_log, "registry.room_enabled", room=room_key, agent=agent_id, transport=transport)

    async def get_room(self, room_key: str) -> RoomRecord | None:
        return self._get_room(room_key)

    # -- active bots (process-local by design) ---------------------------------

    async def set_active_bot(self, room_key: str, pid: int) -> None:
        self._active[room_key] = pid

    async def clear_active_bot(self, room_key: str) -> None:
        self._active.pop(room_key, None)

    async def active_bot(self, room_key: str) -> int | None:
        return self._active.get(room_key)

    # -- VoIP push tokens (inbound calls) ---------------------------------------

    def _get_voip(self, backend_agent_id: str) -> VoipRegistration | None:
        with self._lock:
            row = self._conn.execute(
                """SELECT backend_agent_id, app_agent_id, voip_token, platform, bundle_id
                   FROM voip_tokens WHERE backend_agent_id = ?""",
                (backend_agent_id,),
            ).fetchone()
        return VoipRegistration(*row) if row else None

    async def register_voip(self, registration: VoipRegistration) -> None:
        # Latest registration per backend agent wins (the VoIP token is per-install,
        # app-wide; the app re-registers on every launch).
        with self._lock:
            self._conn.execute(
                "INSERT OR REPLACE INTO voip_tokens VALUES (?, ?, ?, ?, ?, ?)",
                (
                    registration.backend_agent_id,
                    registration.app_agent_id,
                    registration.voip_token,
                    registration.platform,
                    registration.bundle_id,
                    _now(),
                ),
            )
            self._conn.commit()
        event(
            _log,
            "inbound.registered",
            agent=registration.backend_agent_id,
            platform=registration.platform,
            bundle=registration.bundle_id,
        )

    async def get_voip(self, backend_agent_id: str) -> VoipRegistration | None:
        return self._get_voip(backend_agent_id)

    async def delete_voip(self, backend_agent_id: str) -> None:
        with self._lock:
            self._conn.execute(
                "DELETE FROM voip_tokens WHERE backend_agent_id = ?", (backend_agent_id,)
            )
            self._conn.commit()
        event(_log, "inbound.token_evicted", agent=backend_agent_id)


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()
