"""Registry: which rooms are agent-enabled (direct mode), which rooms have an
active bot (idempotent dispatch), and which devices registered a VoIP push token
(inbound calls).

SQLite-backed. Rooms and VoIP tokens persist across restarts when
``REGISTRY_DB_PATH`` points at durable storage (e.g. a mounted volume); with the
default cwd file or an ephemeral filesystem, a redeploy loses them — direct-mode
dispatch until re-provisioned, inbound rings until the app registers its token
again (on save, or when PushKit next hands it the token, usually at launch). Active-bot state is deliberately in-memory only: pids are
process-local (bots die with the dispatcher), and persisting the SPAWNING sentinel
would permanently block a room after a crash mid-spawn.

Single-process only, like the dispatcher itself: SQLite here does not make
multi-replica deployments safe (dispatch idempotency still relies on one event
loop). Keep one replica.
"""

from __future__ import annotations

import json
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
    # Sent by newer app builds; None for registrations from older builds.
    display_name: str | None = None
    handle: str | None = None
    # The optional push features the app's engine supports ("cancel",
    # "ring_timeout", and names added later). Empty for older builds, which send
    # none: a server must then use none of them.
    push_features: tuple[str, ...] = ()
    # The call-control signals the app's calls carry ("call-connected", ...). Empty
    # for older builds: a bot started for their rings greets when they are ready.
    call_signals: tuple[str, ...] = ()
    # The transport the app's agent calls over. None for older builds: a ring then
    # cannot know which room to prepare.
    transport: str | None = None


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
            self._migrate_voip_tokens()
            self._conn.commit()

    def _migrate_voip_tokens(self) -> None:
        # CREATE TABLE IF NOT EXISTS leaves a database created by an older build
        # untouched, so add any columns it predates. Caller holds the lock.
        existing = {row[1] for row in self._conn.execute("PRAGMA table_info(voip_tokens)")}
        for column in ("display_name", "handle", "push_features", "call_signals", "transport"):
            if column not in existing:
                self._conn.execute(f"ALTER TABLE voip_tokens ADD COLUMN {column} TEXT")

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
                """SELECT backend_agent_id, app_agent_id, voip_token, platform, bundle_id,
                          display_name, handle, push_features, call_signals, transport
                   FROM voip_tokens WHERE backend_agent_id = ?""",
                (backend_agent_id,),
            ).fetchone()
        if row is None:
            return None
        return VoipRegistration(
            backend_agent_id=row[0],
            app_agent_id=row[1],
            voip_token=row[2],
            platform=row[3],
            bundle_id=row[4],
            display_name=row[5],
            handle=row[6],
            push_features=tuple(json.loads(row[7])) if row[7] else (),
            call_signals=tuple(json.loads(row[8])) if row[8] else (),
            transport=row[9],
        )

    async def register_voip(self, registration: VoipRegistration) -> None:
        # Latest registration per backend agent wins (the VoIP token is per-install,
        # app-wide; the app registers on save and whenever PushKit hands it a token).
        with self._lock:
            self._conn.execute(
                """INSERT OR REPLACE INTO voip_tokens
                       (backend_agent_id, app_agent_id, voip_token, platform, bundle_id,
                        display_name, handle, push_features, call_signals, transport,
                        updated_at)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (
                    registration.backend_agent_id,
                    registration.app_agent_id,
                    registration.voip_token,
                    registration.platform,
                    registration.bundle_id,
                    registration.display_name,
                    registration.handle,
                    json.dumps(list(registration.push_features)),
                    json.dumps(list(registration.call_signals)),
                    registration.transport,
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
            push_features=",".join(registration.push_features),
            call_signals=",".join(registration.call_signals),
            transport=registration.transport,
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
