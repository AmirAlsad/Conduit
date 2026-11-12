"""Bot launch-mode detection: dispatched-subprocess vs dev runner."""

from bot.bot import _is_dispatch_invocation


def test_dispatch_invocation_detected_by_token():
    assert _is_dispatch_invocation(
        ["--transport", "daily", "--agent", "live", "--token", "x"]
    ) is True


async def test_the_cli_passes_the_await_and_ring_flags_to_run_bot(monkeypatch):
    import sys

    import bot.bot as entry

    seen = {}

    async def fake_run_bot(transport, agent_id, transport_type, **kwargs):
        seen.update(kwargs)

    monkeypatch.setattr(entry, "build_transport", lambda kind, creds: object())
    monkeypatch.setattr(entry, "run_bot", fake_run_bot)
    monkeypatch.setattr(entry, "_stdin_lines", lambda: None)
    monkeypatch.setattr(sys, "argv", [
        "bot", "--transport", "daily", "--agent", "live", "--token", "t", "--room-url", "https://x",
        "--await-connected", "--joins-before-answer", "--ring-deadline", "75",
    ])
    await entry._run_from_cli()
    assert seen["await_connected"] is True
    assert seen["joins_before_answer"] is True
    assert seen["ring_deadline_secs"] == 75

    seen.clear()
    monkeypatch.setattr(sys, "argv", ["bot", "--transport", "daily", "--agent", "live", "--token", "t", "--room-url", "https://x"])
    await entry._run_from_cli()
    assert seen["await_connected"] is False and seen["joins_before_answer"] is False


def test_dev_runner_when_no_token():
    assert _is_dispatch_invocation([]) is False
    assert _is_dispatch_invocation(["-t", "webrtc"]) is False
    assert _is_dispatch_invocation(["-t", "daily"]) is False


async def test_ring_bot_reads_control_lines_from_stdin(monkeypatch):
    # The dispatcher writes the receipt-driven "answered" into a ring bot's stdin pipe.
    import os
    import sys

    from bot.bot import _stdin_lines

    read_fd, write_fd = os.pipe()
    monkeypatch.setattr(sys, "stdin", os.fdopen(read_fd, "rb", buffering=0))
    os.write(write_fd, b"answered\n")
    os.close(write_fd)
    assert [line async for line in _stdin_lines()] == ["answered"]


async def test_report_joined_makes_the_bot_announce_its_join(monkeypatch):
    import sys

    import bot.bot as entry
    from bot.runtime import announce_joined_on_stdout

    seen = {}

    async def fake_run_bot(transport, agent_id, transport_type, **kwargs):
        seen.update(kwargs)

    monkeypatch.setattr(entry, "build_transport", lambda kind, creds: object())
    monkeypatch.setattr(entry, "run_bot", fake_run_bot)
    base = ["bot", "--transport", "daily", "--agent", "live", "--token", "t", "--room-url", "https://x"]
    monkeypatch.setattr(sys, "argv", [*base, "--report-joined"])
    await entry._run_from_cli()
    assert seen["announce_joined"] is announce_joined_on_stdout
    # A plain bot reports nothing: its stdout may not be a pipe to the dispatcher.
    monkeypatch.setattr(sys, "argv", base)
    await entry._run_from_cli()
    assert seen["announce_joined"] is None


def test_the_joined_announcement_is_the_dispatchers_control_line(capsys):
    from app.rings import CONTROL_JOINED, CONTROL_REPLY_PREFIX
    from bot.runtime import announce_joined_on_stdout

    announce_joined_on_stdout()
    assert capsys.readouterr().out == f"{CONTROL_REPLY_PREFIX}{CONTROL_JOINED}\n"


class _Events:
    def __init__(self):
        self.handlers = {}

    def event_handler(self, name):
        def deco(fn):
            self.handlers[name] = fn
            return fn

        return deco


async def test_the_bot_announces_once_when_its_own_transport_joined():
    from app.obs import get_logger
    from bot.runtime import _wire_joined

    for transport_type, event_name, args in (
        ("daily", "on_joined", ({"participants": {}},)),
        ("livekit", "on_connected", ()),
    ):
        t, announced = _Events(), []
        _wire_joined(t, transport_type, lambda: announced.append(1), get_logger("test"))
        assert set(t.handlers) == {event_name}
        await t.handlers[event_name](t, *args)
        # LiveKit can report the connection twice.
        await t.handlers[event_name](t, *args)
        assert announced == [1], transport_type
    t = _Events()
    _wire_joined(t, "smallwebrtc", lambda: None, get_logger("test"))
    assert t.handlers == {}
