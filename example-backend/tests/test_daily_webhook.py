"""Daily webhook signature verification + parsing."""

import base64
import hashlib
import hmac
import json

import pytest

from app.config import settings
from app.transports.daily import DailyService, DailyWebhookError


def _service() -> DailyService:
    # The pure webhook methods don't touch the network; a None session is fine.
    return DailyService(aiohttp_session=None)


def _sign(timestamp: str, raw_body: bytes) -> str:
    secret = base64.b64decode(settings.daily_webhook_secret)
    signed = f"{timestamp}.".encode() + raw_body
    return base64.b64encode(hmac.new(secret, signed, hashlib.sha256).digest()).decode()


def test_valid_signature_parses():
    svc = _service()
    body = json.dumps(
        {"type": "participant.joined", "payload": {"room": "r1", "user_name": "Alice"}}
    ).encode()
    ts = "1700000000"
    evt = svc.verify_and_parse_webhook(body, _sign(ts, body), ts)
    assert DailyService.parse_participant_joined(evt) == ("r1", "Alice")


def test_tampered_body_rejected():
    svc = _service()
    body = json.dumps({"type": "participant.joined", "payload": {"room": "r1"}}).encode()
    ts = "1700000000"
    sig = _sign(ts, body)
    tampered = body.replace(b"r1", b"r2")
    with pytest.raises(DailyWebhookError):
        svc.verify_and_parse_webhook(tampered, sig, ts)


def test_missing_headers_rejected():
    svc = _service()
    with pytest.raises(DailyWebhookError):
        svc.verify_and_parse_webhook(b"{}", None, None)


def test_test_payload_detected():
    svc = _service()
    assert svc.is_test_payload(b'{"test": "test"}') is True
    assert svc.is_test_payload(b'{"type": "participant.joined"}') is False


def test_parse_ignores_other_events():
    assert DailyService.parse_participant_joined({"type": "meeting.started"}) is None
