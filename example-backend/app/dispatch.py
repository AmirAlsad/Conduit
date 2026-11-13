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
from app.rings import CONTROL_JOINED, CONTROL_REPLY_PREFIX

# How long a cancel waits for the ring bot's verdict before the caller falls back
# to force-ending it (the bot may still be importing, with the line waiting in its
# stdin pipe).
CANCEL_REPLY_SECS = 3.0

# wait_joined outcomes.
BOT_JOINED = "joined"
BOT_EXITED = "exited"  # the bot ended (or there is no reporting bot) before joining
BOT_WAIT_TIMEOUT = "timeout"

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
        # A pending cancel's verdict, per room, filled in by the bot's stdout reader.
        self._cancel_waiters: dict[str, asyncio.Future] = {}
        # Whether a bot dispatched with report_joined has joined its room, per room:
        # True once it said so, False if it ended first.
        self._joined: dict[str, asyncio.Future] = {}
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
        control: bool = False,
        report_joined: bool = False,
        bot_env: dict[str, str] | None = None,
    ) -> int | None:
        """Spawn a bot into ``room_key`` unless one is already active there.

        ``control`` gives the bot a stdin pipe that ``send_control`` writes to (ring
        bots read it for the receipt-driven "answered" and for cancels), and a
        stdout pipe its replies come back on. A pipe, not a signal: a line written
        while the bot is still importing waits in the pipe, where a signal would
        hit the default action and kill it. (Logs go to stderr, which stays
        inherited; any other stdout line is forwarded.)

        ``report_joined`` (a bot started with ``--report-joined``) pipes its stdout
        too, for the line it writes once it has joined the room: ``wait_joined``.

        ``bot_env`` is added to the bot's environment: its room token goes there,
        not on argv, which every user on the host can read.

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
            pipe_stdout = control or report_joined
            try:
                proc = await asyncio.create_subprocess_exec(
                    sys.executable,
                    "-m",
                    "bot.bot",
                    *bot_argv,
                    env={**os.environ, **(bot_env or {})},
                    cwd=_PROJECT_ROOT,
                    stdin=asyncio.subprocess.PIPE if control else None,
                    stdout=asyncio.subprocess.PIPE if pipe_stdout else None,
                )
            except Exception as e:
                await self._registry.clear_active_bot(room_key)
                event(self._log, "dispatch.spawn_failed", room=room_key, error=str(e))
                raise

            self._procs[room_key] = proc
            await self._registry.set_active_bot(room_key, proc.pid)
            event(self._log, "dispatch.accepted", room=room_key, agent=agent_id, pid=proc.pid)
            joined = None
            if report_joined:
                joined = asyncio.get_running_loop().create_future()
                self._joined[room_key] = joined
            # Retain a strong reference so the watcher isn't GC'd mid-flight (which
            # would leave a leaked active-bot entry permanently blocking the room).
            self._spawn_task(self._watch(proc, room_key, cleanup, joined))
            if pipe_stdout and getattr(proc, "stdout", None) is not None:
                self._spawn_task(self._read_replies(proc.stdout, room_key))
            return proc.pid

    def _spawn_task(self, coro) -> None:
        task = asyncio.create_task(coro)
        self._watchers.add(task)
        task.add_done_callback(self._watchers.discard)

    async def _read_replies(self, stdout, room_key: str) -> None:
        """Drain a control or reporting bot's stdout: its verdicts resolve a
        pending cancel, its joined line resolves ``wait_joined``, anything else is
        passed through as if the bot had inherited stdout."""
        try:
            while raw := await stdout.readline():
                line = raw.decode(errors="replace").rstrip("\n")
                waiter = self._cancel_waiters.get(room_key)
                if line.startswith(CONTROL_REPLY_PREFIX + "cancel "):
                    if waiter is not None and not waiter.done():
                        waiter.set_result(line.rsplit(" ", 1)[1])
                elif line == CONTROL_REPLY_PREFIX + CONTROL_JOINED:
                    joined = self._joined.get(room_key)
                    if joined is not None and not joined.done():
                        joined.set_result(True)
                        event(self._log, "dispatch.bot_joined", room=room_key)
                else:
                    print(line, flush=True)
        finally:
            # The bot is gone: no verdict will come, and it will not join now.
            waiter = self._cancel_waiters.get(room_key)
            if waiter is not None and not waiter.done():
                waiter.set_result(None)
            joined = self._joined.get(room_key)
            if joined is not None and not joined.done():
                joined.set_result(False)

    async def _watch(
        self,
        proc: asyncio.subprocess.Process,
        room_key: str,
        cleanup: Callable[[], Awaitable[None]] | None,
        joined: asyncio.Future | None = None,
    ) -> None:
        code = await proc.wait()
        await self._registry.clear_active_bot(room_key)
        # Drop the process handle now the bot is gone (safe — it's not a concurrency
        # guard; the per-room lock is intentionally kept, see __init__).
        if self._procs.get(room_key) is proc:
            self._procs.pop(room_key, None)
        if joined is not None:
            if not joined.done():
                joined.set_result(False)
            if self._joined.get(room_key) is joined:
                del self._joined[room_key]
        event(self._log, "dispatch.bot_exited", room=room_key, pid=proc.pid, code=code)
        if cleanup is not None:
            try:
                await cleanup()
            except Exception as e:  # cleanup is best-effort (e.g. delete ephemeral room)
                event(self._log, "dispatch.cleanup_failed", room=room_key, error=str(e))

    def has_bot(self, room_key: str) -> bool:
        """Whether a bot this dispatcher started is still running in the room."""
        proc = self._procs.get(room_key)
        return proc is not None and proc.returncode is None

    async def wait_joined(self, room_key: str, timeout: float) -> str:
        """Wait up to ``timeout`` for the bot dispatched with ``report_joined`` into
        ``room_key`` to say it has joined the room: BOT_JOINED, BOT_EXITED (it
        ended first, or no such bot is running) or BOT_WAIT_TIMEOUT."""
        joined = self._joined.get(room_key)
        if joined is None:
            return BOT_EXITED
        try:
            # Shielded: the future is the room's, not this waiter's.
            ok = await asyncio.wait_for(asyncio.shield(joined), timeout)
        except asyncio.TimeoutError:
            return BOT_WAIT_TIMEOUT
        return BOT_JOINED if ok else BOT_EXITED

    async def send_control(self, room_key: str, message: str) -> bool:
        """Write one control line to a bot dispatched with ``control=True``.
        True if it was written; False if there is no such bot or it has gone."""
        proc = self._procs.get(room_key)
        stdin = getattr(proc, "stdin", None)
        if proc is None or proc.returncode is not None or stdin is None:
            return False
        try:
            stdin.write(f"{message}\n".encode())
            await stdin.drain()
        except (BrokenPipeError, ConnectionResetError):
            return False
        event(self._log, "dispatch.control_sent", room=room_key, message=message)
        return True

    async def cancel_ring_bot(
        self, room_key: str, timeout: float = CANCEL_REPLY_SECS
    ) -> str | None:
        """Ask a ring bot to end for a canceled ring, unless it knows the call was
        answered: the bot decides, so an answer it has already seen can't be
        overridden. Returns its verdict (CANCEL_ENDED / CANCEL_REFUSED), or None
        when it can't be asked or doesn't reply in ``timeout``; the caller then
        falls back to ``disconnect``."""
        waiter = asyncio.get_running_loop().create_future()
        self._cancel_waiters[room_key] = waiter
        try:
            if not await self.send_control(room_key, "cancel"):
                return None
            return await asyncio.wait_for(waiter, timeout)
        except asyncio.TimeoutError:
            event(self._log, "dispatch.cancel_no_reply", room=room_key)
            return None
        finally:
            if self._cancel_waiters.get(room_key) is waiter:
                del self._cancel_waiters[room_key]

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
