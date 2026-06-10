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
    ``transport`` omitted → fall back to the agent's default, then the engine default.
    The default agent is ``loopback`` so a bare deploy works with zero AI-provider
    keys; the path routes (/connect/{agent_id}) override ``agent_id`` entirely."""

    agent_id: str = "loopback"
    transport: Transport | None = None


class DisconnectRequest(BaseModel):
    """POST /admin/disconnect — force-end a bot in a room (deterministic drop test)."""

    room_key: str = Field(..., description="Room name/key the bot is in (idempotency key).")


class VoipRegisterRequest(BaseModel):
    """POST /inbound/register/{agent_id} — the Conduit app registering its VoIP push
    token (docs/INBOUND_CALLS.md §1). The path names OUR agent; the body's
    ``agent_id`` is the app's own UUID for it, echoed back in the push payload."""

    voip_token: str = Field(..., min_length=1)
    platform: str = "ios"
    bundle_id: str = Field(..., min_length=1)
    agent_id: str = Field(..., min_length=1)


class RingRequest(BaseModel):
    """POST /admin/ring/{agent_id} — ring the registered device.

    Default (pairing) mode sends a credential-free push; the app resolves
    /connect/{agent_id} after the user answers, so a declined ring costs nothing.
    ``inline`` provisions a room + token NOW and embeds them in the push — the bot
    is dispatched before the user answers and idles on a decline until the
    pipeline timeouts reap it."""

    inline: bool = False
    transport: Transport | None = None


class RingResponse(BaseModel):
    call_id: str
    agent_id: str  # the app-side UUID the push was addressed to
    mode: Literal["pairing", "inline"]
    apns_status: int
    apns_id: str | None = None


class ConnectionPayload(BaseModel):
    """The connection contract returned by /connect and /credentials.

    ``connection`` is transport-specific:
      daily:   {"room_url": "...", "token": "..."}
      livekit: {"room_url": "wss://...", "url": "wss://...", "token": "...", "room_name": "..."}

    ``room_url`` is the canonical key for both transports (docs/CONNECTION_CONTRACT.md);
    LiveKit also carries ``url`` as a deprecated alias for older consumers.
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
