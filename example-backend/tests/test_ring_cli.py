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


def test_ring_body_carries_the_opt_outs_only_when_asked():
    assert ring.ring_body(inline=False, preconnect="none") == {"inline": False, "preconnect": "none"}
    assert ring.ring_body(inline=True, wait_for_bot=False) == {"inline": True, "wait_for_bot": False}
    assert ring.ring_body(inline=True, wait_for_bot=True) == {"inline": True}


def test_a_default_ring_leaves_the_tier_to_the_engine_and_says_what_was_sent(monkeypatch, capsys):
    rang = (200, {**_RANG[1], "preconnect": "media", "bot_in_room": True, "bot_wait_secs": 2.5})
    calls = _run(monkeypatch, ["--agent", "live"], [rang])
    assert calls == [("/admin/ring/live", {"inline": False})]
    out = capsys.readouterr().out
    assert "Pre-connect: media (the best the device's registration takes)" in out
    assert "joined the room 2.5 s" in out and "prepared the room and bot at ring time" in out


def test_a_default_ring_to_a_device_without_preconnect_says_it_is_plain(monkeypatch, capsys):
    _run(monkeypatch, ["--agent", "live"], [(200, {**_RANG[1], "preconnect": None})])
    out = capsys.readouterr().out
    assert "Pre-connect not sent" in out and "Agent first" not in out


def test_preconnect_none_and_no_wait_reach_the_body(monkeypatch, capsys):
    calls = _run(monkeypatch, ["--agent", "live", "--preconnect", "none", "--no-wait"],
                 [(200, {**_RANG[1], "preconnect": None})])
    assert calls == [("/admin/ring/live", {"inline": False, "preconnect": "none", "wait_for_bot": False})]
    assert "Pre-connect: none (opted out)" in capsys.readouterr().out


def test_ring_reports_a_bot_that_was_not_in_the_room_in_time(monkeypatch, capsys):
    rang = (200, {**_RANG[1], "mode": "inline", "preconnect": "media", "bot_in_room": False, "bot_wait_secs": 8.0})
    _run(monkeypatch, ["--agent", "live", "--inline"], [rang])
    out = capsys.readouterr().out
    assert "not in the room after 8 s; rang anyway" in out
    assert "ring deadline passes" in out


def test_ring_explains_a_ring_withdrawn_before_its_push(monkeypatch, capsys):
    from app.rings import RING_ENDED

    over = (409, {"detail": {"call_id": "c-1", "status": "canceled", "reason": RING_ENDED}})
    with pytest.raises(SystemExit) as exc:
        _run(monkeypatch, ["--agent", "live"], [over])
    assert exc.value.code == 1
    assert "push never went out" in capsys.readouterr().out


def test_cancel_before_the_push_says_nothing_reached_the_phone(monkeypatch, capsys):
    canceled = (200, {"call_id": "c-9", "method": "before_push", "bot_ended": True,
                      "apns_status": None, "apns_id": None})
    _run(monkeypatch, ["--agent", "live", "--cancel", "c-9"], [canceled])
    out = capsys.readouterr().out
    assert "before its push went out" in out and "bot was ended" in out


def test_preconnect_rejects_unknown_tiers(monkeypatch):
    with pytest.raises(SystemExit):
        _run(monkeypatch, ["--preconnect", "everything"], [])
