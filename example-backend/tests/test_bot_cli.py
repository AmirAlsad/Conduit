"""Bot launch-mode detection: dispatched-subprocess vs dev runner."""

from bot.bot import _is_dispatch_invocation


def test_dispatch_invocation_detected_by_token():
    assert _is_dispatch_invocation(
        ["--transport", "daily", "--agent", "live", "--token", "x"]
    ) is True


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
