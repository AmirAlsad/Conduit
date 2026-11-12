"""Inbound-call token registration and ring-status receipts (docs/INBOUND_CALLS.md).

The Conduit app POSTs its device VoIP token here when the user enables "Let this
agent call me" (and on every app launch thereafter). The stored token is what
/admin/ring sends the push to. Latest registration per agent wins — the token is
per-install, app-wide. Newer app builds also send the caller's display name and
CallKit handle, which are stored and echoed in the ring push, the push
features the device supports, which gate cancel pushes and ring_timeout, and the
call-control signals its calls carry, which tell a bot started for a ring to wait
for call-connected before it greets.

/inbound/status is the receipt channel: each ring's push carries a status_url
pointing here, and the app reports how the ring ended (answered / declined /
busy / suppressed_by_focus / unanswered / canceled, and any status a newer app
adds) — so an agent that really needed to reach the user knows whether the ring
landed. The engine logs every receipt and records it on the ring tracker. Only
a ring's first receipt steers its bot (an inline ring's, a pairing ring's
prepared at ring time, or one dispatched when the app paired during the ring):
any status but "answered" ends the bot, and "answered" tells a ring bot (one with
the ring flags) through its control pipe, except a prepared bot whose room the
app never took: the app then connects with a request of its own, so that bot ends.
"""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Request

from app.agents import get_agent
from app.auth import require_engine_key
from app.models import RING_STATUSES, RingStatusRequest, VoipRegisterRequest
from app.obs import event, get_logger
from app.registry import VoipRegistration

router = APIRouter(prefix="/inbound", dependencies=[Depends(require_engine_key)])
_log = get_logger("inbound")


@router.post("/register/{agent_id}")
async def register(agent_id: str, req: VoipRegisterRequest, request: Request):
    try:
        get_agent(agent_id)
    except KeyError:
        raise HTTPException(status_code=404, detail=f"Unknown agent_id: {agent_id!r}")
    await request.app.state.registry.register_voip(
        VoipRegistration(
            backend_agent_id=agent_id,
            app_agent_id=req.agent_id,
            voip_token=req.voip_token,
            platform=req.platform,
            bundle_id=req.bundle_id,
            display_name=req.display_name,
            handle=req.handle,
            push_features=tuple(req.push_features),
            call_signals=tuple(req.call_signals),
        )
    )
    return {"ok": True}


@router.delete("/register/{agent_id}")
async def unregister(agent_id: str, request: Request):
    """The app deleted the agent — drop its registration so we stop ringing.
    Idempotent: deleting a registration that doesn't exist is still ok."""
    try:
        get_agent(agent_id)
    except KeyError:
        raise HTTPException(status_code=404, detail=f"Unknown agent_id: {agent_id!r}")
    await request.app.state.registry.delete_voip(agent_id)
    event(_log, "inbound.unregistered", agent=agent_id)
    return {"ok": True}


@router.post("/status/{agent_id}")
async def ring_status(agent_id: str, req: RingStatusRequest, request: Request):
    try:
        get_agent(agent_id)
    except KeyError:
        raise HTTPException(status_code=404, detail=f"Unknown agent_id: {agent_id!r}")
    fields = {"agent": agent_id, "call_id": req.call_id, "status": req.status}
    if req.status not in RING_STATUSES:
        fields["known"] = False
    event(_log, "inbound.ring_status", **fields)

    state = request.app.state
    ring = state.rings.get(req.call_id)
    # One receipt per ring: only the first one steers the ring's bot, so a stray
    # duplicate can't end a call that was answered.
    if ring is None or ring.agent_id != agent_id or ring.status is not None:
        return {"ok": True}
    ring.status = req.status
    ring.ended.set()
    if ring.room_key:
        if req.status == "answered":
            if ring.prepared is not None:
                # Answered without taking the room prepared for it: the app connects
                # with a fresh request, so this bot would wait for nobody. A late
                # request for the ring then gets a fresh room too.
                ring.prepared = None
                ended = await state.dispatcher.disconnect(ring.room_key)
                event(
                    _log,
                    "inbound.prepared_bot_unclaimed",
                    call_id=req.call_id,
                    room=ring.room_key,
                    ended=ended,
                )
            elif ring.ring_bot:
                # Stops the bot's deadline and starts its fallback wait for
                # call-connected (the app sends this receipt before its audio is up).
                await state.dispatcher.send_control(ring.room_key, "answered")
        else:
            ended = await state.dispatcher.disconnect(ring.room_key)
            event(
                _log,
                "inbound.ring_bot_ended",
                call_id=req.call_id,
                status=req.status,
                ended=ended,
            )
    return {"ok": True}
