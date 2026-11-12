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
