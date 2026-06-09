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
