"""SFU webhook ingress.

On a participant-joined event for a *registered direct-mode room with no active
bot*, dispatch a bot. Must verify the signature (the caller is the SFU, not a
user) and be idempotent. Respond 200 fast — both SFUs flip a slow webhook to
FAILED — and do the dispatch in a background task (design §2.1, §3).

LiveKit's handler is added in build step 4.
"""

from __future__ import annotations

import asyncio

from fastapi import APIRouter, HTTPException, Request

from app.config import MissingSettingError, settings
from app.obs import event, get_logger
from app.provisioning import dispatch_for_webhook
from app.transports.daily import DailyService, DailyWebhookError
from app.transports.livekit import LiveKitService, LiveKitWebhookError

router = APIRouter(prefix="/webhooks")
_log = get_logger("webhook")

# Hold strong references to in-flight dispatch tasks: a bare asyncio.create_task()
# can be garbage-collected mid-flight, silently cancelling the dispatch.
_inflight: set[asyncio.Task] = set()


def _spawn_dispatch(state, record) -> None:
    task = asyncio.create_task(_safe_dispatch(state, record))
    _inflight.add(task)
    task.add_done_callback(_inflight.discard)


async def _safe_dispatch(state, record) -> None:
    try:
        await dispatch_for_webhook(state, record)
    except Exception as e:  # background task: log, never crash the webhook response
        event(_log, "webhook.dispatch_failed", room=record.room_key, error=str(e))


@router.post("/daily")
async def daily_webhook(request: Request):
    state = request.app.state
    daily: DailyService | None = getattr(state, "daily", None)
    if daily is None:
        raise HTTPException(status_code=503, detail="Daily not configured.")

    raw = await request.body()

    # Daily's creation/reactivation probe — accept 200 without signature.
    if daily.is_test_payload(raw):
        event(_log, "webhook.daily_test")
        return {"ok": True}

    try:
        evt = daily.verify_and_parse_webhook(
            raw,
            request.headers.get("X-Webhook-Signature"),
            request.headers.get("X-Webhook-Timestamp"),
        )
    except DailyWebhookError as e:
        event(_log, "webhook.daily_rejected", error=str(e))
        raise HTTPException(status_code=401, detail="Invalid webhook signature.")
    except MissingSettingError as e:
        # DAILY_WEBHOOK_SECRET unset — server misconfig, not a bad signature. Return a
        # clean 503 rather than a 500 (a 500 still counts toward Daily's FAILED breaker,
        # but at least this won't read as an unhandled crash in logs/alerts).
        event(_log, "webhook.daily_misconfigured", error=str(e))
        raise HTTPException(status_code=503, detail="Webhook secret not configured.")

    parsed = DailyService.parse_participant_joined(evt)
    if parsed is None:
        return {"ok": True}  # some other event type; ignore

    room_name, user_name = parsed
    event(_log, "webhook.daily_received", event="participant.joined", room=room_name, user=user_name)

    # Belt-and-suspenders: ignore the bot's own join (also absorbed by active-at-spawn).
    if user_name == settings.bot_name:
        event(_log, "webhook.ignored_bot_join", room=room_name)
        return {"ok": True}

    record = await state.registry.get_room(room_name)
    if record is None:
        event(_log, "webhook.unregistered_room", room=room_name)
        return {"ok": True}

    _spawn_dispatch(state, record)
    return {"ok": True}


@router.post("/livekit")
async def livekit_webhook(request: Request):
    state = request.app.state
    livekit: LiveKitService | None = getattr(state, "livekit", None)
    if livekit is None:
        raise HTTPException(status_code=503, detail="LiveKit not configured.")

    raw = await request.body()
    try:
        evt = livekit.verify_and_parse_webhook(raw, request.headers.get("Authorization"))
    except LiveKitWebhookError as e:
        event(_log, "webhook.livekit_rejected", error=str(e))
        raise HTTPException(status_code=401, detail="Invalid webhook signature.")

    parsed = LiveKitService.parse_participant_joined(evt)
    if parsed is None:
        return {"ok": True}  # some other event type; ignore

    room_name, participant_name = parsed
    event(
        _log,
        "webhook.livekit_received",
        event="participant_joined",
        room=room_name,
        participant=participant_name,
    )

    if participant_name == settings.bot_name:
        event(_log, "webhook.ignored_bot_join", room=room_name)
        return {"ok": True}

    record = await state.registry.get_room(room_name)
    if record is None:
        event(_log, "webhook.unregistered_room", room=room_name)
        return {"ok": True}

    _spawn_dispatch(state, record)
    return {"ok": True}
