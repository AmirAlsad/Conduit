"""LiveKit token grants + connection-contract helpers."""

import jwt

from app.config import settings
from app.models import ConnectionPayload, iso_expiry
from app.transports.livekit import LiveKitService


def test_livekit_agent_and_user_grants():
    lk = LiveKitService()

    agent = jwt.decode(
        lk.agent_token("room-1", ttl_secs=300),
        settings.livekit_api_secret,
        algorithms=["HS256"],
    )
    assert agent["video"]["room"] == "room-1"
    assert agent["video"]["roomJoin"] is True
    assert agent["video"]["agent"] is True

    user = jwt.decode(
        lk.user_token("room-1", ttl_secs=300),
        settings.livekit_api_secret,
        algorithms=["HS256"],
    )
    assert user["video"]["agent"] is False
    # TTL gates the initial connect; assert it was set.
    assert user["exp"] > user["nbf"]


def test_iso_expiry():
    assert iso_expiry(None) is None
    assert iso_expiry(300).endswith("+00:00")


def test_connection_payload_shape():
    p = ConnectionPayload(
        transport="livekit",
        connection={"url": "wss://x", "token": "t", "room_name": "r"},
        agent_id="live",
        expires_at=None,
    )
    assert p.model_dump()["transport"] == "livekit"
    assert set(p.connection) == {"url", "token", "room_name"}
