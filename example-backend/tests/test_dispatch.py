"""Idempotent dispatch (the load-bearing guarantee) + admin disconnect."""

import asyncio

from app.dispatch import BOT_EXITED, BOT_JOINED, BOT_WAIT_TIMEOUT, Dispatcher
from app.rings import CANCEL_ENDED, CANCEL_REFUSED, CONTROL_JOINED, CONTROL_REPLY_PREFIX
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


def _reply(verdict):
    return f"{CONTROL_REPLY_PREFIX}cancel {verdict}\n".encode()


class ReplyingStdin(FakeStdin):
    """A ring bot's stdin that answers each cancel line on its stdout."""

    def __init__(self, stdout, verdict):
        super().__init__()
        self.stdout = stdout
        self.verdict = verdict

    def write(self, data):
        super().write(data)
        if data == b"cancel\n" and self.verdict is not None:
            self.stdout.feed_data(_reply(self.verdict))


async def _control_dispatcher(monkeypatch, verdict):
    disp = Dispatcher(SQLiteRegistry(":memory:"))
    proc = FakeProc()
    proc.stdout = asyncio.StreamReader()
    proc.stdin = ReplyingStdin(proc.stdout, verdict)
    seen = {}

    async def fake_exec(*args, **kwargs):
        seen.update(kwargs)
        return proc

    monkeypatch.setattr(asyncio, "create_subprocess_exec", fake_exec)
    await disp.dispatch(
        room_key="r1", agent_id="live", transport="daily",
        bot_argv=["--token", "t", "--ring-deadline", "75"], control=True,
    )
    return disp, proc, seen


async def test_control_dispatch_pipes_stdout_for_the_bots_replies(monkeypatch):
    _, _, seen = await _control_dispatcher(monkeypatch, CANCEL_ENDED)
    assert seen["stdout"] is asyncio.subprocess.PIPE


async def test_plain_dispatch_keeps_inherited_stdout(monkeypatch):
    disp = Dispatcher(SQLiteRegistry(":memory:"))
    seen = {}

    async def fake_exec(*args, **kwargs):
        seen.update(kwargs)
        return FakeProc()

    monkeypatch.setattr(asyncio, "create_subprocess_exec", fake_exec)
    await disp.dispatch(room_key="r1", agent_id="live", transport="daily", bot_argv=["--token", "t"])
    assert seen.get("stdout") is None


async def test_cancel_ring_bot_returns_the_bots_verdict(monkeypatch):
    for verdict in (CANCEL_ENDED, CANCEL_REFUSED):
        disp, proc, _ = await _control_dispatcher(monkeypatch, verdict)
        assert await disp.cancel_ring_bot("r1") == verdict
        assert proc.stdin.written == b"cancel\n"
        assert not proc.terminated  # the bot decides; the dispatcher never signals it


async def test_cancel_ring_bot_is_none_when_the_bot_cannot_answer(monkeypatch):
    disp, proc, _ = await _control_dispatcher(monkeypatch, None)
    assert await disp.cancel_ring_bot("r1", timeout=0.05) is None  # no reply in time
    assert await disp.cancel_ring_bot("nope") is None  # no such bot
    proc.stdin.broken = True
    assert await disp.cancel_ring_bot("r1") is None  # the pipe is gone


async def test_cancel_ring_bot_is_none_when_the_bot_exits_without_replying(monkeypatch):
    disp, proc, _ = await _control_dispatcher(monkeypatch, None)
    task = asyncio.create_task(disp.cancel_ring_bot("r1", timeout=5))
    await asyncio.sleep(0)
    proc.stdout.feed_eof()
    assert await asyncio.wait_for(task, 1) is None


async def test_bot_stdout_noise_is_forwarded_not_mistaken_for_a_reply(monkeypatch, capsys):
    disp, proc, _ = await _control_dispatcher(monkeypatch, None)
    task = asyncio.create_task(disp.cancel_ring_bot("r1", timeout=5))
    await asyncio.sleep(0)
    proc.stdout.feed_data(b"some library banner\n")
    proc.stdout.feed_data(_reply(CANCEL_ENDED))
    assert await asyncio.wait_for(task, 1) == CANCEL_ENDED
    assert "some library banner" in capsys.readouterr().out


# --- the joined report a ring's push waits for ---


def _joined_line():
    return f"{CONTROL_REPLY_PREFIX}{CONTROL_JOINED}\n".encode()


async def _reporting_dispatcher(monkeypatch, *, control=False):
    disp = Dispatcher(SQLiteRegistry(":memory:"))
    proc = FakeProc()
    proc.stdout = asyncio.StreamReader()
    proc.stdin = FakeStdin() if control else None
    seen = {}

    async def fake_exec(*args, **kwargs):
        seen.update(kwargs)
        return proc

    monkeypatch.setattr(asyncio, "create_subprocess_exec", fake_exec)
    await disp.dispatch(
        room_key="r1", agent_id="live", transport="daily",
        bot_argv=["--token", "t", "--report-joined"], control=control, report_joined=True,
    )
    return disp, proc, seen


async def test_a_reporting_bot_gets_a_stdout_pipe_but_keeps_its_stdin(monkeypatch):
    _, _, seen = await _reporting_dispatcher(monkeypatch)
    assert seen["stdout"] is asyncio.subprocess.PIPE
    assert seen["stdin"] is None


async def test_wait_joined_returns_when_the_bot_says_it_joined(monkeypatch, capsys):
    disp, proc, _ = await _reporting_dispatcher(monkeypatch)
    task = asyncio.create_task(disp.wait_joined("r1", 5))
    await asyncio.sleep(0.01)
    assert not task.done()
    proc.stdout.feed_data(_joined_line())
    assert await asyncio.wait_for(task, 1) == BOT_JOINED
    # Already joined: a later wait returns at once. The line is not forwarded.
    assert await disp.wait_joined("r1", 0.01) == BOT_JOINED
    assert CONTROL_JOINED not in capsys.readouterr().out


async def test_wait_joined_sees_a_line_written_before_it_was_called(monkeypatch):
    disp, proc, _ = await _reporting_dispatcher(monkeypatch)
    proc.stdout.feed_data(_joined_line())
    await asyncio.sleep(0.01)
    assert await disp.wait_joined("r1", 0.01) == BOT_JOINED


async def test_wait_joined_times_out_and_the_bot_can_still_join_later(monkeypatch):
    disp, proc, _ = await _reporting_dispatcher(monkeypatch)
    assert await disp.wait_joined("r1", 0.05) == BOT_WAIT_TIMEOUT
    proc.stdout.feed_data(_joined_line())
    assert await disp.wait_joined("r1", 1) == BOT_JOINED


async def test_wait_joined_ends_when_the_bot_exits_first(monkeypatch):
    disp, proc, _ = await _reporting_dispatcher(monkeypatch)
    task = asyncio.create_task(disp.wait_joined("r1", 5))
    await asyncio.sleep(0.01)
    proc.stdout.feed_eof()
    proc.finish()
    assert await asyncio.wait_for(task, 1) == BOT_EXITED
    for _ in range(50):
        await asyncio.sleep(0)
    assert disp.has_bot("r1") is False
    assert await disp.wait_joined("r1", 1) == BOT_EXITED
    assert await disp.wait_joined("nope", 1) == BOT_EXITED


async def test_a_ring_bot_reports_its_join_on_the_control_pipe_too(monkeypatch):
    disp, proc, seen = await _reporting_dispatcher(monkeypatch, control=True)
    assert seen["stdin"] is asyncio.subprocess.PIPE
    proc.stdout.feed_data(_joined_line())
    assert await disp.wait_joined("r1", 1) == BOT_JOINED
    assert await disp.send_control("r1", "answered") is True


async def test_has_bot_follows_the_bots_life(monkeypatch):
    disp, proc, _ = await _reporting_dispatcher(monkeypatch)
    assert disp.has_bot("r1") is True
    assert disp.has_bot("nope") is False
    await disp.disconnect("r1")
    assert disp.has_bot("r1") is False
