"""Dispatch core: spawn a bot subprocess into a room, idempotently, and manage its
lifecycle (design §2.1, §2.5).

The same core serves both triggers (pairing /connect and direct webhook). It does
not know which one called it. Idempotency is the load-bearing property: a room
gets at most one bot, even under concurrent participant-joined events (including
the bot's own join, which both SFUs report).

⚠️ Correctness here assumes a SINGLE dispatcher process. The per-room asyncio.Lock
and the in-memory registry only serialize within one event loop — run two replicas
(or uvicorn --workers > 1) and concurrent webhooks on different processes will each
see an empty registry and both spawn a bot into the same room. Keep this a single
process until the registry is moved to a shared store with atomic compare-and-set.
"""

from __future__ import annotations

import asyncio
import os
import sys
from collections.abc import Awaitable, Callable
from pathlib import Path

from app.obs import event, get_logger
from app.registry import Registry

# Sentinel pid stored inside the dispatch lock before the subprocess exists, so a
# racing trigger sees the room as already-active and skips. Never terminated.
SPAWNING = -1

# Project root — passed as the subprocess cwd so `python -m bot.bot` can import
# `app`/`bot` regardless of where the dispatcher's start command was run from.
_PROJECT_ROOT = str(Path(__file__).resolve().parent.parent)


class Dispatcher:
    def __init__(self, registry: Registry):
        self._registry = registry
        # One lock per distinct room_key, kept for the dispatcher's lifetime. We do
        # NOT evict it on bot exit: dropping a lock and lazily recreating it would let
        # two dispatches for the same room hold different lock objects and both spawn
        # once the registry's check/set actually suspends (a persistent async store).
        # Growth is one small Lock per room ever seen — negligible for this workload;
        # revisit eviction together with the persistent-registry swap.
        self._locks: dict[str, asyncio.Lock] = {}
        # Live bot subprocess handles, keyed by room. Used to terminate by handle
        # (not a bare pid → no PID-reuse hazard) and to keep watcher tasks alive.
        self._procs: dict[str, asyncio.subprocess.Process] = {}
        self._watchers: set[asyncio.Task] = set()
        self._log = get_logger("dispatch")

    def _lock(self, room_key: str) -> asyncio.Lock:
        # get/create is atomic here: no await between get and set on a single loop.
        lock = self._locks.get(room_key)
        if lock is None:
            lock = asyncio.Lock()
            self._locks[room_key] = lock
        return lock

    async def dispatch(
        self,
        *,
        room_key: str,
        agent_id: str,
        transport: str,
        bot_argv: list[str],
        cleanup: Callable[[], Awaitable[None]] | None = None,
    ) -> int | None:
        """Spawn a bot into ``room_key`` unless one is already active there.

        Returns the new pid, or None if an active bot made this a no-op.
        """
        async with self._lock(room_key):
            existing = await self._registry.active_bot(room_key)
            if existing is not None:
                event(self._log, "dispatch.skip_idempotent", room=room_key, existing_pid=existing)
                return None

            # Mark active BEFORE spawning so the bot's own join webhook is absorbed.
            await self._registry.set_active_bot(room_key, SPAWNING)
            event(
                self._log,
                "dispatch.requested",
                room=room_key,
                agent=agent_id,
                transport=transport,
            )
            try:
                proc = await asyncio.create_subprocess_exec(
                    sys.executable,
                    "-m",
                    "bot.bot",
                    *bot_argv,
                    env=os.environ.copy(),
                    cwd=_PROJECT_ROOT,
                )
            except Exception as e:
                await self._registry.clear_active_bot(room_key)
                event(self._log, "dispatch.spawn_failed", room=room_key, error=str(e))
                raise

            self._procs[room_key] = proc
            await self._registry.set_active_bot(room_key, proc.pid)
            event(self._log, "dispatch.accepted", room=room_key, agent=agent_id, pid=proc.pid)
            # Retain a strong reference so the watcher isn't GC'd mid-flight (which
            # would leave a leaked active-bot entry permanently blocking the room).
            watcher = asyncio.create_task(self._watch(proc, room_key, cleanup))
            self._watchers.add(watcher)
            watcher.add_done_callback(self._watchers.discard)
            return proc.pid

    async def _watch(
        self,
        proc: asyncio.subprocess.Process,
        room_key: str,
        cleanup: Callable[[], Awaitable[None]] | None,
    ) -> None:
        code = await proc.wait()
        await self._registry.clear_active_bot(room_key)
        # Drop the process handle now the bot is gone (safe — it's not a concurrency
        # guard; the per-room lock is intentionally kept, see __init__).
        if self._procs.get(room_key) is proc:
            self._procs.pop(room_key, None)
        event(self._log, "dispatch.bot_exited", room=room_key, pid=proc.pid, code=code)
        if cleanup is not None:
            try:
                await cleanup()
            except Exception as e:  # cleanup is best-effort (e.g. delete ephemeral room)
                event(self._log, "dispatch.cleanup_failed", room=room_key, error=str(e))

    async def disconnect(self, room_key: str) -> bool:
        """Force-end the bot in a room (admin drop test). True if one was signalled."""
        proc = self._procs.get(room_key)
        if proc is None or proc.returncode is not None:
            return False
        try:
            # terminate() the held handle (SIGTERM) — WorkerRunner handles SIGTERM →
            # graceful leave. Using the handle avoids signalling a reused pid.
            proc.terminate()
            event(self._log, "dispatch.admin_disconnect", room=room_key, pid=proc.pid)
            return True
        except ProcessLookupError:
            self._procs.pop(room_key, None)
            await self._registry.clear_active_bot(room_key)
            event(self._log, "dispatch.admin_disconnect_stale", room=room_key, pid=proc.pid)
            return False
