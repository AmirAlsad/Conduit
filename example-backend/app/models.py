"""Request/response models, including the connection contract (design §4).

The contract is internal and forward-compatible — NOT a frozen public spec yet.
Both pairing and direct return the same shape; they differ only in token lifetime.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import Annotated, Literal

from pydantic import AfterValidator, BaseModel, Field

Transport = Literal["daily", "livekit", "smallwebrtc"]
Preconnect = Literal["credentials", "media"]
# What a ring may ask for: a tier, or "none" for a plain ring (no preconnect key).
PreconnectRequest = Literal["credentials", "media", "none"]
PushFeature = Annotated[str, Field(min_length=1, max_length=64)]
# A call-control signal the client says its calls carry ("call-connected", ...).
CallSignalName = Annotated[str, Field(min_length=1, max_length=64)]
CALL_CONNECTED = "call-connected"
# A ring's call_id as the app sends it back. The engine issues lowercase UUIDs; the
# app's engine sends lowercase from 0.2 on (earlier engines sent Swift's uppercase
# uuidString), and the push contract says to compare ids case-insensitively, so
# every call_id is folded before any lookup.
CallID = Annotated[str, Field(min_length=1), AfterValidator(str.lower)]

# The receipt statuses the app sends today (docs/INBOUND_CALLS.md §4). Receipts are
# not validated against this set: a server must accept statuses it doesn't know.
RING_STATUSES = (
    "answered",
    "declined",
    "busy",
    "suppressed_by_focus",
    "unanswered",
    "canceled",
)


class RingContext(BaseModel):
    """The ring a pairing request is made for: the app sends it when it fetches
    credentials while the phone is still ringing (``preconnect``)."""

    call_id: CallID
    # True when the app will join the room before the user answers ("media"): its
    # joining is then not the answer, and the bot must stay silent until it is.
    joins_before_answer: bool = False


class ConnectRequest(BaseModel):
    """POST /connect (pairing) and POST /credentials (direct) share this body.
    ``transport`` omitted → fall back to the agent's default, then the engine default.
    The default agent is ``loopback`` so a bare deploy works with zero AI-provider
    keys; the path routes (/connect/{agent_id}) override ``agent_id`` entirely.
    ``ring`` is pairing-only and ignored by /credentials. ``call_signals`` lists
    the call-control signals the client's calls carry; with "call-connected" the
    bot stays silent until the user is on the line. Older clients omit it."""

    agent_id: str = "loopback"
    transport: Transport | None = None
    ring: RingContext | None = None
    call_signals: list[CallSignalName] = Field(default_factory=list, max_length=32)

    @property
    def sends_call_connected(self) -> bool:
        return CALL_CONNECTED in self.call_signals


class DisconnectRequest(BaseModel):
    """POST /admin/disconnect — force-end a bot in a room (deterministic drop test)."""

    room_key: str = Field(..., description="Room name/key the bot is in (idempotency key).")


class VoipRegisterRequest(BaseModel):
    """POST /inbound/register/{agent_id} — the Conduit app registering its VoIP push
    token (docs/INBOUND_CALLS.md §1). The path names OUR agent; the body's
    ``agent_id`` is the app's own UUID for it, echoed back in the push payload.

    ``display_name`` and ``handle`` (the caller's name and CallKit handle) are sent
    by newer app builds and omitted by older ones; they are stored and echoed in
    the push only when present.

    ``push_features`` lists the optional push features the app's engine supports
    (``CallEngine.supportedPushFeatures``: "cancel", "ring_timeout", and names
    added later, kept as sent). Older builds omit it: an empty list, meaning the
    engine uses none of them with this device. ``call_signals`` lists the
    call-control signals the app's calls carry; a bot started for a ring before
    the app asks for credentials waits for "call-connected" only when it is listed,
    and a "media" ring needs it."""

    voip_token: str = Field(..., min_length=1)
    platform: str = "ios"
    bundle_id: str = Field(..., min_length=1)
    agent_id: str = Field(..., min_length=1)
    display_name: str | None = Field(default=None, max_length=128)
    handle: str | None = Field(default=None, max_length=256)
    push_features: list[PushFeature] = Field(default_factory=list, max_length=32)
    call_signals: list[CallSignalName] = Field(default_factory=list, max_length=32)


class RingRequest(BaseModel):
    """POST /admin/ring/{agent_id} — ring the registered device.

    Default (pairing) mode sends a credential-free push; the app resolves
    /connect/{agent_id} after the user answers, so a declined ring costs nothing.
    ``inline`` provisions a room + token NOW and embeds them in the push — the bot
    is dispatched before the user answers, and ended when the ring's first receipt
    is anything but "answered".

    ``ring_timeout`` and ``preconnect`` ride the push only to a device whose
    registration lists the "ring_timeout" / "preconnect" push feature; any other
    device rings for its own default, and a ``preconnect`` is dropped.

    Agent-first: a ring that starts its bot before the push (inline, and a
    pre-connected pairing ring, whose room and bot are prepared at ring time)
    sends the push once the bot has joined the room, or after
    RING_BOT_WAIT_SECS without it. ``wait_for_bot: false`` pushes at once and
    prepares nothing for a pairing ring (its bot starts at the app's request)."""

    inline: bool = False
    # The transport of the room made at ring time (inline, or a prepared pairing
    # ring): match the app's for the agent.
    transport: Transport | None = None
    # Shortens this ring (whole seconds; the app clamps it to [10, its own timeout]).
    ring_timeout: int | None = Field(default=None, gt=0)
    # Ask the app to prepare during the ring: "credentials" fetches /connect while
    # ringing, "media" also joins the room (the bot then waits for call-connected;
    # a device that does not list it gets "credentials"). Omitted: the best tier
    # the registration takes. "none": a plain ring, with no preconnect key.
    preconnect: PreconnectRequest | None = None
    wait_for_bot: bool = True


class RingCancelRequest(BaseModel):
    """POST /admin/ring/{agent_id}/cancel — withdraw a ring that is still ringing."""

    call_id: CallID


class RingCancelResponse(BaseModel):
    call_id: str
    # "in_band": the agent left the pre-connected room (no push).
    # "push": a cancel push was sent.
    # "before_push": the ring was still waiting for its bot, so its push never
    # went out (and never will).
    method: Literal["in_band", "push", "before_push"]
    bot_ended: bool
    apns_status: int | None = None
    apns_id: str | None = None


class RingResponse(BaseModel):
    call_id: str
    agent_id: str  # the app-side UUID the push was addressed to
    display_name: str | None = None  # the caller name the app registered, if any
    mode: Literal["pairing", "inline"]
    # The ring_timeout the push carried: None when the request set none or the
    # device doesn't list the "ring_timeout" push feature (it then rings for its
    # own default).
    ring_timeout: int | None = None
    # Likewise the preconnect the push carried: None for "none", or when the
    # device doesn't list the "preconnect" push feature (the ring then behaves as
    # one that never asked, and no ring bot is dispatched for it).
    preconnect: Preconnect | None = None
    # Agent-first ringing: whether the bot started for this ring had joined its
    # room when the push went out (False: the wait ran out, or the bot exited).
    # None when the ring did not wait (no bot at ring time, or wait_for_bot false).
    bot_in_room: bool | None = None
    # How long the push waited for that bot, in seconds; None when it did not wait.
    bot_wait_secs: float | None = None
    apns_status: int
    apns_id: str | None = None


class RingStatusRequest(BaseModel):
    """POST /inbound/status/{agent_id} — the app reporting how a ring ended
    (docs/INBOUND_CALLS.md, ring-status receipts). Fire-and-forget on the app
    side. ``status`` is any string: RING_STATUSES lists today's values, and newer
    apps may send more."""

    call_id: CallID
    status: str = Field(..., min_length=1, max_length=64)


class ConnectionPayload(BaseModel):
    """The connection contract returned by /connect and /credentials.

    ``connection`` is transport-specific:
      daily:       {"room_url": "...", "token": "..."}
      livekit:     {"room_url": "wss://...", "url": "wss://...", "token": "...", "room_name": "..."}
      smallwebrtc: {"room_url": "http(s)://<engine>/webrtc/<agent>/offer", "token": "<ephemeral>"}

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
