"""Request/response models, including the connection contract (design §4).

The contract is internal and forward-compatible — NOT a frozen public spec yet.
Both pairing and direct return the same shape; they differ only in token lifetime.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import Literal

from pydantic import BaseModel, Field

Transport = Literal["daily", "livekit"]


class ConnectRequest(BaseModel):
    """POST /connect (pairing) and POST /credentials (direct) share this body.
    ``transport`` omitted → fall back to the agent's default, then the engine default."""

    agent_id: str = "live"
    transport: Transport | None = None


class DisconnectRequest(BaseModel):
    """POST /admin/disconnect — force-end a bot in a room (deterministic drop test)."""

    room_key: str = Field(..., description="Room name/key the bot is in (idempotency key).")


class ConnectionPayload(BaseModel):
    """The connection contract returned by /connect and /credentials.

    ``connection`` is transport-specific:
      daily:   {"room_url": "...", "token": "..."}
      livekit: {"url": "wss://...", "token": "...", "room_name": "..."}
    """

    transport: Transport
    connection: dict
    agent_id: str
    expires_at: str | None  # ISO8601; short for pairing, long/null for direct


def iso_expiry(ttl_secs: int | None) -> str | None:
    """ISO8601 expiry ``ttl_secs`` from now, or None for non-expiring."""
    if ttl_secs is None:
        return None
    return (datetime.now(timezone.utc) + timedelta(seconds=ttl_secs)).isoformat()
