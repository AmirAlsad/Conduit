"""Provisioning: the shared core behind both credential modes.

Pairing (/connect) and direct (/credentials) converge here, differing only in
token lifetime, whether the room is registered, and whether the bot is dispatched
now (pairing) or later by a webhook (direct). The webhook path reuses
``dispatch_for_webhook``. All three ultimately call the one dispatch core.
"""

from __future__ import annotations

import uuid

from app.config import settings
from app.models import ConnectionPayload, iso_expiry
from app.registry import RoomRecord


class TransportUnavailable(Exception):
    """Requested transport isn't configured on this engine."""


def _daily(state):
    if getattr(state, "daily", None) is None:
        raise TransportUnavailable("Daily is not configured (set DAILY_API_KEY).")
    return state.daily


def _livekit(state):
    if getattr(state, "livekit", None) is None:
        raise TransportUnavailable("LiveKit is not configured (set LIVEKIT_* env).")
    return state.livekit


def _livekit_connection(server_url: str, token: str, room_name: str) -> dict:
    # `room_url` is the canonical key (docs/CONNECTION_CONTRACT.md — what the app
    # reads); `url` stays as a deprecated alias for the web client and older scripts.
    return {"room_url": server_url, "url": server_url, "token": token, "room_name": room_name}


# --- pairing: create per-call creds and dispatch the bot now ---


async def provision_pairing(
    state, agent_id: str, transport: str, *, base_url: str | None = None
) -> ConnectionPayload:
    if transport == "daily":
        daily = _daily(state)
        room = await daily.create_room(exp_secs=settings.pairing_room_exp_secs)
        app_token = await daily.mint_token(
            room.url, ttl_secs=settings.pairing_token_ttl_secs, owner=False
        )
        bot_token = await daily.mint_token(
            room.url, ttl_secs=settings.pairing_token_ttl_secs, owner=True
        )
        argv = [
            "--transport", "daily", "--agent", agent_id,
            "--room-url", room.url, "--token", bot_token,
        ]

        async def cleanup() -> None:
            await daily.delete_room_by_url(room.url)  # ephemeral pairing room

        await state.dispatcher.dispatch(
            room_key=room.name, agent_id=agent_id, transport="daily",
            bot_argv=argv, cleanup=cleanup,
        )
        return ConnectionPayload(
            transport="daily",
            connection={"room_url": room.url, "token": app_token},
            agent_id=agent_id,
            expires_at=iso_expiry(settings.pairing_token_ttl_secs),
        )

    if transport == "livekit":
        lk = _livekit(state)
        room_name = f"conduit-{uuid.uuid4().hex[:12]}"
        app_token = lk.user_token(room_name, ttl_secs=settings.pairing_token_ttl_secs)
        bot_token = lk.agent_token(room_name, ttl_secs=settings.pairing_token_ttl_secs)
        argv = [
            "--transport", "livekit", "--agent", agent_id,
            "--url", lk.url, "--room-name", room_name, "--token", bot_token,
        ]
        # LiveKit Cloud auto-closes empty rooms; no cleanup needed.
        await state.dispatcher.dispatch(
            room_key=room_name, agent_id=agent_id, transport="livekit", bot_argv=argv,
        )
        return ConnectionPayload(
            transport="livekit",
            connection=_livekit_connection(lk.url, app_token, room_name),
            agent_id=agent_id,
            expires_at=iso_expiry(settings.pairing_token_ttl_secs),
        )

    if transport == "smallwebrtc":
        # No room, no dispatch: the client's offer POST is the rendezvous and the
        # bot spawns in-process when it lands (app/transports/smallwebrtc.py).
        # The "credential" is the offer URL plus a short-lived bearer for it.
        base = (settings.public_base_url or base_url or "").rstrip("/")
        if not base:
            raise TransportUnavailable(
                "smallwebrtc needs a reachable base URL (set PUBLIC_BASE_URL)."
            )
        token = state.smallwebrtc.mint_token(agent_id, settings.pairing_token_ttl_secs)
        return ConnectionPayload(
            transport="smallwebrtc",
            connection={"room_url": f"{base}/webrtc/{agent_id}/offer", "token": token},
            agent_id=agent_id,
            expires_at=iso_expiry(settings.pairing_token_ttl_secs),
        )

    raise TransportUnavailable(f"Unknown transport: {transport!r}")


# --- direct: create stable creds, register, dispatch later via webhook ---


async def provision_direct(state, agent_id: str, transport: str) -> ConnectionPayload:
    if transport == "daily":
        daily = _daily(state)
        room = await daily.create_room(exp_secs=settings.direct_room_exp_secs)
        app_token = await daily.mint_token(
            room.url, ttl_secs=settings.direct_token_ttl_secs, owner=False
        )
        await state.registry.enable_room(room.name, agent_id, "daily", room_url=room.url)
        return ConnectionPayload(
            transport="daily",
            connection={"room_url": room.url, "token": app_token},
            agent_id=agent_id,
            expires_at=iso_expiry(settings.direct_token_ttl_secs),
        )

    if transport == "livekit":
        lk = _livekit(state)
        room_name = f"conduit-{uuid.uuid4().hex[:12]}"
        app_token = lk.user_token(room_name, ttl_secs=settings.direct_token_ttl_secs)
        await state.registry.enable_room(room_name, agent_id, "livekit", room_url=None)
        return ConnectionPayload(
            transport="livekit",
            connection=_livekit_connection(lk.url, app_token, room_name),
            agent_id=agent_id,
            expires_at=iso_expiry(settings.direct_token_ttl_secs),
        )

    if transport == "smallwebrtc":
        raise TransportUnavailable(
            "smallwebrtc is pairing-only; for direct use, point the app at the "
            "offer URL with the engine key as the token."
        )

    raise TransportUnavailable(f"Unknown transport: {transport!r}")


# --- webhook-time dispatch for a registered direct-mode room ---


async def dispatch_for_webhook(state, record: RoomRecord) -> int | None:
    """Mint a fresh bot token for a registered room and dispatch (idempotent)."""
    if record.transport == "daily":
        daily = _daily(state)
        bot_token = await daily.mint_token(
            record.room_url, ttl_secs=settings.pairing_token_ttl_secs, owner=True
        )
        argv = [
            "--transport", "daily", "--agent", record.agent_id,
            "--room-url", record.room_url, "--token", bot_token,
        ]
        return await state.dispatcher.dispatch(
            room_key=record.room_key, agent_id=record.agent_id,
            transport="daily", bot_argv=argv,
        )

    if record.transport == "livekit":
        lk = _livekit(state)
        bot_token = lk.agent_token(record.room_key, ttl_secs=settings.pairing_token_ttl_secs)
        argv = [
            "--transport", "livekit", "--agent", record.agent_id,
            "--url", lk.url, "--room-name", record.room_key, "--token", bot_token,
        ]
        return await state.dispatcher.dispatch(
            room_key=record.room_key, agent_id=record.agent_id,
            transport="livekit", bot_argv=argv,
        )

    raise TransportUnavailable(f"Unknown transport: {record.transport!r}")
