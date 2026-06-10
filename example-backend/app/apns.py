"""APNs VoIP push sender (inbound calls — docs/INBOUND_CALLS.md §2).

Rings a Conduit install by POSTing a VoIP push to Apple for a registered device
token. APNs' provider API is HTTP/2-only, hence httpx with the h2 extra; auth is
an ES256 provider JWT signed with the developer's .p8 key (PyJWT + the
already-transitive cryptography).
"""

from __future__ import annotations

import base64
import time
from dataclasses import dataclass

import httpx
import jwt

from app.config import settings
from app.obs import event, get_logger

_log = get_logger("apns")

# Apple requires provider tokens be refreshed every 20–60 minutes; re-mint at 50.
_JWT_MAX_AGE_SECS = 50 * 60

# Hints keyed on APNs' `reason` string, surfaced to the operator via /admin/ring.
REASON_HINTS = {
    "BadDeviceToken": (
        "The token doesn't match this APNs environment — check APNS_USE_SANDBOX "
        "against how the app was signed (Xcode dev builds → sandbox)."
    ),
    "Unregistered": (
        "The device token is no longer valid (app reinstalled/removed). The stale "
        "registration was evicted — re-enable inbound in the app to re-register."
    ),
    "InvalidProviderToken": "Check APNS_KEY_ID / APNS_TEAM_ID / the .p8 key contents.",
    "ExpiredProviderToken": "Provider JWT rejected as expired — retry; the cache was cleared.",
    "MissingProviderToken": "No provider JWT reached Apple — check APNs configuration.",
    "TopicDisallowed": (
        "The apns-topic isn't allowed for this key — is Push Notifications enabled "
        "on the App ID, and does the topic match <bundle-id>.voip?"
    ),
}


@dataclass
class ApnsResult:
    status: int  # HTTP status from APNs (200 = delivered to Apple)
    reason: str | None = None  # APNs `reason` string on non-200
    apns_id: str | None = None

    @property
    def hint(self) -> str | None:
        return REASON_HINTS.get(self.reason or "")


class ApnsSender:
    """Validates its settings at point of use (config.require pattern), so it can
    be constructed unconditionally at startup like the transport services."""

    def __init__(self, client: httpx.AsyncClient) -> None:
        self._client = client
        self._key_pem: bytes | None = None
        self._jwt: str | None = None
        self._jwt_issued_at = 0.0

    def _load_key(self) -> bytes:
        if self._key_pem is None:
            settings.require("apns_key_id", "apns_team_id")
            if settings.apns_key_path:
                self._key_pem = open(settings.apns_key_path, "rb").read()
            else:
                settings.require("apns_key_base64")
                self._key_pem = base64.b64decode(settings.apns_key_base64)
        return self._key_pem

    def _provider_jwt(self) -> str:
        now = time.time()
        if self._jwt is None or now - self._jwt_issued_at > _JWT_MAX_AGE_SECS:
            self._jwt = jwt.encode(
                {"iss": settings.apns_team_id, "iat": int(now)},
                self._load_key(),
                algorithm="ES256",
                headers={"kid": settings.apns_key_id},
            )
            self._jwt_issued_at = now
        return self._jwt

    async def send_voip_push(self, *, voip_token: str, bundle_id: str, payload: dict) -> ApnsResult:
        host = "api.sandbox.push.apple.com" if settings.apns_use_sandbox else "api.push.apple.com"
        topic = settings.apns_topic or f"{bundle_id}.voip"
        resp = await self._client.post(
            f"https://{host}/3/device/{voip_token}",
            json=payload,
            headers={
                "authorization": f"bearer {self._provider_jwt()}",
                "apns-topic": topic,
                "apns-push-type": "voip",
                "apns-priority": "10",
                # A ring is deliver-now-or-never; a queued stale ring would be a ghost call.
                "apns-expiration": "0",
            },
        )
        reason = None
        if resp.status_code != 200:
            try:
                reason = resp.json().get("reason")
            except Exception:
                reason = resp.text or None
            if reason in ("ExpiredProviderToken", "InvalidProviderToken"):
                self._jwt = None  # re-mint on the next attempt
        event(_log, "apns.push_sent", status=resp.status_code, reason=reason, topic=topic)
        return ApnsResult(
            status=resp.status_code, reason=reason, apns_id=resp.headers.get("apns-id")
        )
