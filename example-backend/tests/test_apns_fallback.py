"""APNs environment fallback (apns.py).

A VoIP device token is valid on exactly one APNs environment and doesn't reveal
which, so the sender tries a preferred host and falls back to the other on
BadDeviceToken — dev-signed (sandbox) and TestFlight/App Store (production) builds
both ring without reconfiguration. These drive the real ApnsSender with a fake
httpx client (no network, no .p8 key) to lock that behavior in.
"""

import pytest

from app.apns import _PRODUCTION_HOST, _SANDBOX_HOST, ApnsSender
from app.config import settings


class FakeResponse:
    def __init__(self, status_code: int, reason: str | None = None, apns_id: str = "apns-x"):
        self.status_code = status_code
        self._reason = reason
        self.text = reason or ""
        self.headers = {"apns-id": apns_id}

    def json(self) -> dict:
        return {"reason": self._reason} if self._reason else {}


class FakeClient:
    """Returns a scripted response per host and records the hosts hit, in order."""

    def __init__(self, by_host: dict[str, FakeResponse]):
        self._by_host = by_host
        self.hosts: list[str] = []

    async def post(self, url, json=None, headers=None):
        host = url.removeprefix("https://").split("/3/device/")[0]
        self.hosts.append(host)
        return self._by_host[host]


def _sender(by_host, monkeypatch, *, prefer_sandbox: bool):
    client = FakeClient(by_host)
    sender = ApnsSender(client)
    # Skip JWT signing (needs a real EC key); we only care about host routing here.
    monkeypatch.setattr(sender, "_provider_jwt", lambda: "fake-jwt")
    monkeypatch.setattr(settings, "apns_use_sandbox", prefer_sandbox)
    monkeypatch.setattr(settings, "apns_topic", None)
    return sender, client


async def _ring(sender):
    return await sender.send_voip_push(
        voip_token="tok", bundle_id="com.example.Conduit", payload={}
    )


async def test_production_token_rings_even_when_sandbox_is_preferred(monkeypatch):
    sender, client = _sender(
        {
            _SANDBOX_HOST: FakeResponse(400, "BadDeviceToken"),
            _PRODUCTION_HOST: FakeResponse(200),
        },
        monkeypatch,
        prefer_sandbox=True,
    )
    result = await _ring(sender)
    assert result.status == 200
    assert client.hosts == [_SANDBOX_HOST, _PRODUCTION_HOST]  # fell back to production


async def test_sandbox_token_rings_with_production_first_default(monkeypatch):
    sender, client = _sender(
        {
            _PRODUCTION_HOST: FakeResponse(400, "BadDeviceToken"),
            _SANDBOX_HOST: FakeResponse(200),
        },
        monkeypatch,
        prefer_sandbox=False,
    )
    result = await _ring(sender)
    assert result.status == 200
    assert client.hosts == [_PRODUCTION_HOST, _SANDBOX_HOST]  # fell back to sandbox


async def test_matched_first_try_skips_the_fallback(monkeypatch):
    sender, client = _sender(
        {
            _PRODUCTION_HOST: FakeResponse(200),
            _SANDBOX_HOST: FakeResponse(200),
        },
        monkeypatch,
        prefer_sandbox=False,
    )
    result = await _ring(sender)
    assert result.status == 200
    assert client.hosts == [_PRODUCTION_HOST]  # only one round-trip


async def test_non_environment_error_does_not_fall_back(monkeypatch):
    # A credentials error isn't an environment mismatch; retrying the other host would
    # be pointless and would mask the real failure.
    sender, client = _sender(
        {
            _PRODUCTION_HOST: FakeResponse(403, "InvalidProviderToken"),
            _SANDBOX_HOST: FakeResponse(200),
        },
        monkeypatch,
        prefer_sandbox=False,
    )
    result = await _ring(sender)
    assert result.status == 403
    assert result.reason == "InvalidProviderToken"
    assert client.hosts == [_PRODUCTION_HOST]  # no fallback


async def test_both_environments_reject_returns_bad_token(monkeypatch):
    sender, client = _sender(
        {
            _PRODUCTION_HOST: FakeResponse(400, "BadDeviceToken"),
            _SANDBOX_HOST: FakeResponse(400, "BadDeviceToken"),
        },
        monkeypatch,
        prefer_sandbox=False,
    )
    result = await _ring(sender)
    assert result.status == 400
    assert result.reason == "BadDeviceToken"
    assert client.hosts == [_PRODUCTION_HOST, _SANDBOX_HOST]  # tried both, then gave up
    assert "both" in (result.hint or "").lower()
