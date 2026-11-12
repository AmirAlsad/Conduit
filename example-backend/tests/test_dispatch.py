"""Idempotent dispatch (the load-bearing guarantee) + admin disconnect."""

import asyncio

from app.dispatch import Dispatcher
from app.registry import SQLiteRegistry


class FakeProc:
    _counter = 1000

    def __init__(self):
        FakeProc._counter += 1
        self.pid = FakeProc._counter
        self._done = asyncio.Event()
        self.returncode = None
        self.terminated = False

    async def wait(self):
        await self._done.wait()
        return 0

    def terminate(self):
        self.terminated = True
        self.finish()

    def finish(self):
        self.returncode = 0
        self._done.set()


async def test_concurrent_dispatch_spawns_exactly_one(monkeypatch):
    reg = SQLiteRegistry(":memory:")
    disp = Dispatcher(reg)
    procs: list[FakeProc] = []
    calls = 0

    async def fake_exec(*args, **kwargs):
        nonlocal calls
        calls += 1
        p = FakeProc()
        procs.append(p)
        return p

    monkeypatch.setattr(asyncio, "create_subprocess_exec", fake_exec)

    # 5 concurrent triggers into the same room (mimics duplicate participant.joined,
    # including the bot's own join).
    results = await asyncio.gather(
        *[
            disp.dispatch(
                room_key="r1", agent_id="loopback", transport="daily",
                bot_argv=["--token", "t"],
            )
            for _ in range(5)
        ]
    )
    spawned = [r for r in results if r is not None]
    assert calls == 1, "exactly one subprocess spawned"
    assert len(spawned) == 1
    assert await reg.active_bot("r1") == spawned[0]

    # When the bot exits, the watcher clears the active mapping.
    procs[0].finish()
    for _ in range(50):
        await asyncio.sleep(0)
        if await reg.active_bot("r1") is None:
            break
    assert await reg.active_bot("r1") is None


async def test_dispatch_runs_cleanup_on_exit(monkeypatch):
    reg = SQLiteRegistry(":memory:")
    disp = Dispatcher(reg)
    proc = FakeProc()

    async def fake_exec(*args, **kwargs):
        return proc

    monkeypatch.setattr(asyncio, "create_subprocess_exec", fake_exec)

    cleaned = asyncio.Event()

    async def cleanup():
        cleaned.set()

    await disp.dispatch(
        room_key="r1", agent_id="loopback", transport="daily",
        bot_argv=["--token", "t"], cleanup=cleanup,
    )
    proc.finish()
    await asyncio.wait_for(cleaned.wait(), timeout=1.0)
    assert cleaned.is_set()


async def test_disconnect_terminates_held_handle(monkeypatch):
    reg = SQLiteRegistry(":memory:")
    disp = Dispatcher(reg)
    proc = FakeProc()

    async def fake_exec(*args, **kwargs):
        return proc

    monkeypatch.setattr(asyncio, "create_subprocess_exec", fake_exec)

    # No bot in this room → False (and nothing to terminate)
    assert await disp.disconnect("nope") is False

    # Dispatch a bot, then disconnect terminates the HELD handle (not a bare pid →
    # no PID-reuse hazard).
    await disp.dispatch(
        room_key="r1", agent_id="loopback", transport="daily", bot_argv=["--token", "t"]
    )
    assert await disp.disconnect("r1") is True
    assert proc.terminated is True

    # Once the bot has exited and the watcher cleared it, a second disconnect is a no-op.
    for _ in range(50):
        await asyncio.sleep(0)
        if await reg.active_bot("r1") is None:
            break
    assert await disp.disconnect("r1") is False


class FakeStdin:
    def __init__(self, broken=False):
        self.written = b""
        self.broken = broken

    def write(self, data):
        if self.broken:
            raise BrokenPipeError
        self.written += data

    async def drain(self):
        pass


async def test_control_dispatch_gets_a_stdin_pipe_and_send_control_writes_lines(monkeypatch):
    reg = SQLiteRegistry(":memory:")
    disp = Dispatcher(reg)
    proc = FakeProc()
    proc.stdin = FakeStdin()
    seen = {}

    async def fake_exec(*args, **kwargs):
        seen.update(kwargs)
        return proc

    monkeypatch.setattr(asyncio, "create_subprocess_exec", fake_exec)
    await disp.dispatch(
        room_key="r1", agent_id="live", transport="daily",
        bot_argv=["--token", "t", "--ring-deadline", "75"], control=True,
    )
    assert seen["stdin"] is asyncio.subprocess.PIPE
    assert await disp.send_control("r1", "answered") is True
    assert proc.stdin.written == b"answered\n"
    assert await disp.send_control("nope", "answered") is False

    proc.stdin.broken = True  # the bot exited between our check and the write
    assert await disp.send_control("r1", "answered") is False


async def test_plain_dispatch_keeps_inherited_stdin_and_cannot_be_controlled(monkeypatch):
    reg = SQLiteRegistry(":memory:")
    disp = Dispatcher(reg)
    proc = FakeProc()
    proc.stdin = None
    seen = {}

    async def fake_exec(*args, **kwargs):
        seen.update(kwargs)
        return proc

    monkeypatch.setattr(asyncio, "create_subprocess_exec", fake_exec)
    await disp.dispatch(
        room_key="r1", agent_id="live", transport="daily", bot_argv=["--token", "t"]
    )
    assert seen["stdin"] is None
    assert await disp.send_control("r1", "answered") is False
