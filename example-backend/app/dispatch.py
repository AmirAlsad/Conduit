"""Dispatch core: spawn a bot subprocess into a room, idempotently, and manage its
lifecycle (design §2.1, §2.5).

The same core serves both triggers (pairing /connect and direct webhook). It does
not know which one called it. Idempotency is the load-bearing property: a room
gets at most one bot, even under concurrent participant-joined events (including
the bot's own join, which both SFUs report).
"""

from __future__ import annotations

import asyncio
import os
import signal
import sys
from collections.abc import Awaitable, Callable

from app.obs import event, get_logger
from app.registry import Registry

# Sentinel pid stored inside the dispatch lock before the subprocess exists, so a
# racing trigger sees the room as already-active and skips. Never SIGTERM'd.
SPAWNING = -1


class Dispatcher:
    def __init__(self, registry: Registry):
        self._registry = registry
        self._locks: dict[str, asyncio.Lock] = {}
        self._log = get_logger("dispatch")

    def _lock(self, room_key: str) -> asyncio.Lock:
        # setdefault is atomic here: no await between get and set on a single loop.
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
                )
            except Exception as e:
                await self._registry.clear_active_bot(room_key)
                event(self._log, "dispatch.spawn_failed", room=room_key, error=str(e))
                raise

            await self._registry.set_active_bot(room_key, proc.pid)
            event(self._log, "dispatch.accepted", room=room_key, agent=agent_id, pid=proc.pid)
            asyncio.create_task(self._watch(proc, room_key, cleanup))
            return proc.pid

    async def _watch(
        self,
        proc: asyncio.subprocess.Process,
        room_key: str,
        cleanup: Callable[[], Awaitable[None]] | None,
    ) -> None:
        code = await proc.wait()
        await self._registry.clear_active_bot(room_key)
        event(self._log, "dispatch.bot_exited", room=room_key, pid=proc.pid, code=code)
        if cleanup is not None:
            try:
                await cleanup()
            except Exception as e:  # cleanup is best-effort (e.g. delete ephemeral room)
                event(self._log, "dispatch.cleanup_failed", room=room_key, error=str(e))

    async def disconnect(self, room_key: str) -> bool:
        """Force-end the bot in a room (admin drop test). True if one was signalled."""
        pid = await self._registry.active_bot(room_key)
        if pid is None or pid == SPAWNING:
            return False
        try:
            os.kill(pid, signal.SIGTERM)  # WorkerRunner handles SIGTERM → graceful leave
            event(self._log, "dispatch.admin_disconnect", room=room_key, pid=pid)
            return True
        except ProcessLookupError:
            await self._registry.clear_active_bot(room_key)
            event(self._log, "dispatch.admin_disconnect_stale", room=room_key, pid=pid)
            return False
