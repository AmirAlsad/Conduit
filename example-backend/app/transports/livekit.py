"""LiveKit Cloud: server-side token minting and webhook verify/parse.

Tokens are minted with ``livekit.api.AccessToken`` (the bot gets the ``agent``
grant). LiveKit Cloud auto-creates the room on join, so there's no room-create
call. Webhooks are verified with ``WebhookReceiver``/``TokenVerifier`` (the
Authorization header is a signed JWT carrying a sha256 of the body).
"""

from __future__ import annotations

import uuid
from datetime import timedelta

from livekit import api

from app.config import settings
from app.obs import event, get_logger

_log = get_logger("livekit")


class LiveKitWebhookError(Exception):
    """Raised when a LiveKit webhook fails verification or parsing."""


class LiveKitService:
    def __init__(self) -> None:
        settings.require("livekit_api_key", "livekit_api_secret", "livekit_url")
        self._key = settings.livekit_api_key
        self._secret = settings.livekit_api_secret
        self.url = settings.livekit_url
        self._receiver = api.WebhookReceiver(api.TokenVerifier(self._key, self._secret))

    # --- tokens ---

    def _token(self, room_name: str, *, name: str, agent: bool, ttl_secs: int) -> str:
        identity = f"{'bot' if agent else 'user'}-{uuid.uuid4().hex[:10]}"
        grants = api.VideoGrants(room_join=True, room=room_name, agent=agent)
        return (
            api.AccessToken(self._key, self._secret)
            .with_identity(identity)
            .with_name(name)
            .with_grants(grants)
            .with_ttl(timedelta(seconds=ttl_secs))
            .to_jwt()
        )

    def user_token(self, room_name: str, *, ttl_secs: int) -> str:
        return self._token(room_name, name="User", agent=False, ttl_secs=ttl_secs)

    def agent_token(self, room_name: str, *, ttl_secs: int) -> str:
        # The agent grant makes LiveKit clients aware an agent has joined.
        return self._token(room_name, name=settings.bot_name, agent=True, ttl_secs=ttl_secs)

    # --- webhook ---

    def verify_and_parse_webhook(self, raw_body: bytes, auth_header: str | None):
        if not auth_header:
            raise LiveKitWebhookError("Missing Authorization header")
        try:
            return self._receiver.receive(raw_body.decode("utf-8"), auth_header)
        except Exception as e:  # invalid signature / malformed body
            raise LiveKitWebhookError(f"LiveKit webhook verification failed: {e}") from e

    @staticmethod
    def parse_participant_joined(evt) -> tuple[str, str] | None:
        """Return (room_name, participant_name) for participant_joined, else None."""
        if getattr(evt, "event", None) != "participant_joined":
            return None
        return evt.room.name, evt.participant.name
