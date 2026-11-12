"""scripts/ring.py — request bodies for the new flags, and the cancel flows,
with the HTTP call faked."""

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))

import ring  # noqa: E402


def test_ring_body_omits_unset_options():
    assert ring.ring_body(inline=False) == {"inline": False}
    assert ring.ring_body(
        inline=True, transport="livekit", ring_timeout=30, preconnect="media"
    ) == {"inline": True, "transport": "livekit", "ring_timeout": 30, "preconnect": "media"}


def _run(monkeypatch, argv, responses):
    calls = []
    pending = list(responses)

    def fake_post(base_url, path, body):
        calls.append((path, body))
        return pending.pop(0)

    monkeypatch.setattr(ring, "_post", fake_post)
    monkeypatch.setattr(ring.time, "sleep", lambda secs: calls.append(("sleep", secs)))
    monkeypatch.setattr(sys, "argv", ["ring.py", *argv])
    ring.main()
    return calls


_RANG = (200, {"call_id": "c-1", "agent_id": "u", "display_name": "Ada", "mode": "pairing",
               "apns_status": 200, "apns_id": "a"})
_CANCELED = (200, {"call_id": "c-1", "method": "push", "bot_ended": False,
                   "apns_status": 200, "apns_id": "b"})


def test_cancel_after_rings_waits_then_cancels(monkeypatch, capsys):
    calls = _run(
        monkeypatch,
        ["--agent", "live", "--preconnect", "media", "--ring-timeout", "20", "--cancel-after", "5"],
        [_RANG, _CANCELED],
    )
    assert calls == [
        ("/admin/ring/live", {"inline": False, "ring_timeout": 20, "preconnect": "media"}),
        ("sleep", 5.0),
        ("/admin/ring/live/cancel", {"call_id": "c-1"}),
    ]
    assert "cancel push" in capsys.readouterr().out


def test_cancel_only_sends_the_cancel(monkeypatch):
    calls = _run(monkeypatch, ["--agent", "live", "--cancel", "c-9"], [_CANCELED])
    assert calls == [("/admin/ring/live/cancel", {"call_id": "c-9"})]


def test_cancel_conflict_exits_nonzero(monkeypatch, capsys):
    with pytest.raises(SystemExit) as exc:
        _run(monkeypatch, ["--cancel", "c-9"], [(409, {"detail": "ring ended"})])
    assert exc.value.code == 1
    assert "already over" in capsys.readouterr().out


def test_cancel_and_cancel_after_are_exclusive(monkeypatch):
    with pytest.raises(SystemExit):
        _run(monkeypatch, ["--cancel", "c-9", "--cancel-after", "3"], [])


def test_cancel_refused_for_an_unsupporting_device_explains_why(monkeypatch, capsys):
    refused = (409, {"detail": {"call_id": "c-9", "status": None,
                                "reason": ring.CANCEL_UNSUPPORTED}})
    with pytest.raises(SystemExit) as exc:
        _run(monkeypatch, ["--cancel", "c-9"], [refused])
    assert exc.value.code == 1
    out = capsys.readouterr().out
    assert "push feature" in out and "already over" not in out


def test_ring_notes_a_ring_timeout_the_device_could_not_take(monkeypatch, capsys):
    rang = (200, {**_RANG[1], "ring_timeout": None})
    _run(monkeypatch, ["--agent", "live", "--ring-timeout", "20"], [rang])
    assert "Ring timeout not sent" in capsys.readouterr().out
    _run(monkeypatch, ["--agent", "live", "--ring-timeout", "20"], [(200, {**_RANG[1], "ring_timeout": 20})])
    assert "Ring timeout not sent" not in capsys.readouterr().out


def test_ring_notes_a_preconnect_the_device_could_not_take(monkeypatch, capsys):
    rang = (200, {**_RANG[1], "preconnect": None})
    _run(monkeypatch, ["--agent", "live", "--preconnect", "media"], [rang])
    assert "Pre-connect not sent" in capsys.readouterr().out
    _run(monkeypatch, ["--agent", "live", "--preconnect", "media"], [(200, {**_RANG[1], "preconnect": "media"})])
    out = capsys.readouterr().out
    assert "Pre-connect not sent" not in out and "Pre-connect requested: media" in out


def test_ring_notes_a_media_ring_sent_as_credentials(monkeypatch, capsys):
    rang = (200, {**_RANG[1], "preconnect": "credentials"})
    _run(monkeypatch, ["--agent", "live", "--preconnect", "media"], [rang])
    out = capsys.readouterr().out
    assert "Pre-connect sent as credentials" in out and "call-connected" in out


def test_cancel_refused_because_the_bot_saw_the_answer_says_the_call_is_live(monkeypatch, capsys):
    refused = (409, {"detail": {"call_id": "c-9", "status": "answered",
                                "reason": ring.CANCEL_ANSWERED}})
    with pytest.raises(SystemExit) as exc:
        _run(monkeypatch, ["--cancel", "c-9"], [refused])
    assert exc.value.code == 1
    out = capsys.readouterr().out
    assert "already answered" in out and "already over" not in out


def test_ring_body_carries_the_opt_out_only_when_asked():
    assert ring.ring_body(inline=False, preconnect="none") == {"inline": False, "preconnect": "none"}


def test_a_default_ring_leaves_the_tier_to_the_engine_and_says_what_was_sent(monkeypatch, capsys):
    rang = (200, {**_RANG[1], "preconnect": "media"})
    calls = _run(monkeypatch, ["--agent", "live"], [rang])
    assert calls == [("/admin/ring/live", {"inline": False})]
    assert "Pre-connect: media (the best the device's registration takes)" in capsys.readouterr().out


def test_a_default_ring_to_a_device_without_preconnect_says_it_is_plain(monkeypatch, capsys):
    _run(monkeypatch, ["--agent", "live"], [(200, {**_RANG[1], "preconnect": None})])
    assert "Pre-connect not sent" in capsys.readouterr().out


def test_preconnect_none_reaches_the_body(monkeypatch, capsys):
    calls = _run(monkeypatch, ["--agent", "live", "--preconnect", "none"],
                 [(200, {**_RANG[1], "preconnect": None})])
    assert calls == [("/admin/ring/live", {"inline": False, "preconnect": "none"})]
    assert "Pre-connect: none (opted out)" in capsys.readouterr().out


def test_preconnect_rejects_unknown_tiers(monkeypatch):
    with pytest.raises(SystemExit):
        _run(monkeypatch, ["--preconnect", "everything"], [])
