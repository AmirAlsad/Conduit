"""Daily Cloud: room creation, server-side token minting, and webhook verify/parse.

Wraps Pipecat's ``DailyRESTHelper`` for room/token operations and implements the
Daily webhook HMAC check (design §2.1, §3). Token minting is server-side only,
using ``DAILY_API_KEY``.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import time

import aiohttp
from pipecat.transports.daily.utils import (
    DailyMeetingTokenParams,
    DailyMeetingTokenProperties,
    DailyRESTHelper,
    DailyRoomObject,
    DailyRoomParams,
    DailyRoomProperties,
)

from app.config import settings
from app.obs import event, get_logger

_log = get_logger("daily")


class DailyWebhookError(Exception):
    """Raised when a Daily webhook fails signature verification or parsing."""


class DailyService:
    def __init__(self, aiohttp_session: aiohttp.ClientSession):
        settings.require("daily_api_key")
        self._helper = DailyRESTHelper(
            daily_api_key=settings.daily_api_key,
            daily_api_url=settings.daily_api_url,
            aiohttp_session=aiohttp_session,
        )

    # --- rooms & tokens ---

    async def create_room(self, *, exp_secs: int, name: str | None = None) -> DailyRoomObject:
        """Create a private room that auto-closes (and ejects) at expiry."""
        props = DailyRoomProperties(exp=time.time() + exp_secs, eject_at_room_exp=True)
        room = await self._helper.create_room(
            DailyRoomParams(name=name, privacy="private", properties=props)
        )
        event(_log, "daily.room_created", room=room.name, url=room.url, exp_secs=exp_secs)
        return room

    async def mint_token(self, room_url: str, *, ttl_secs: int, owner: bool) -> str:
        """Mint a meeting token for a room. ``owner`` grants admin (used for the bot)."""
        params = DailyMeetingTokenParams(
            properties=DailyMeetingTokenProperties(
                user_name=settings.bot_name if owner else "User",
            )
        )
        return await self._helper.get_token(
            room_url, expiry_time=ttl_secs, owner=owner, params=params
        )

    async def delete_room_by_url(self, room_url: str) -> None:
        await self._helper.delete_room_by_url(room_url)
        event(_log, "daily.room_deleted", url=room_url)

    def room_name_from_url(self, room_url: str) -> str:
        return self._helper.get_name_from_url(room_url)

    # --- webhook ---

    def is_test_payload(self, raw_body: bytes) -> bool:
        """Daily POSTs ``{"test":"test"}`` when (re)creating a webhook — accept 200."""
        try:
            return json.loads(raw_body) == {"test": "test"}
        except (ValueError, TypeError):
            return False

    def verify_and_parse_webhook(
        self, raw_body: bytes, signature: str | None, timestamp: str | None
    ) -> dict:
        """Verify ``X-Webhook-Signature`` over ``"{timestamp}.{raw_body}"`` with the
        base-64 HMAC secret, then return the parsed event. Raises DailyWebhookError."""
        settings.require("daily_webhook_secret")
        if not signature or not timestamp:
            raise DailyWebhookError("Missing X-Webhook-Signature / X-Webhook-Timestamp")

        secret = base64.b64decode(settings.daily_webhook_secret)
        signed = f"{timestamp}.".encode() + raw_body
        expected = base64.b64encode(hmac.new(secret, signed, hashlib.sha256).digest()).decode()
        if not hmac.compare_digest(expected, signature):
            raise DailyWebhookError("Daily webhook signature mismatch")

        try:
            return json.loads(raw_body)
        except ValueError as e:
            raise DailyWebhookError(f"Invalid webhook JSON: {e}") from e

    @staticmethod
    def parse_participant_joined(event_obj: dict) -> tuple[str, str] | None:
        """Return (room_name, user_name) for a participant.joined event, else None."""
        if event_obj.get("type") != "participant.joined":
            return None
        payload = event_obj.get("payload", {})
        return payload.get("room", ""), payload.get("user_name", "")
