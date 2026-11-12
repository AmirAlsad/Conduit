"""Admin endpoints: force-disconnect a bot, and ring a registered device.

- POST /admin/disconnect — the clean way to simulate a mid-call drop so the
  client's reconnection-with-spoken-state path can be tested deterministically
  (design §2.1, §6 Layer 2).
- POST /admin/ring/{agent_id} — agent-initiated inbound call: send a VoIP push
  to the device that registered via /inbound/register (docs/INBOUND_CALLS.md §2).
- POST /admin/ring/{agent_id}/cancel — withdraw a ring that is still ringing:
  in-band (the agent leaves the pre-connected room) or with a cancel push. Never
  ends the bot of an answered call (see _end_ring_bot).

Optional push keys go only to devices whose registration lists the matching
push feature ("ring_timeout", "preconnect", "cancel"): an older app would ignore
a ring_timeout or a preconnect (and answer a pre-connected ring into a bot that
waits for a call-answered it never sends), and would show a cancel push as a
brief incoming call.
"""

from __future__ import annotations

import uuid

from fastapi import APIRouter, Body, Depends, HTTPException, Request

from app.agents import get_agent, resolve_transport
from app.auth import require_engine_key
from app.config import MissingSettingError, settings
from app.models import (
    DisconnectRequest,
    RingCancelRequest,
    RingCancelResponse,
    RingRequest,
    RingResponse,
)
from app.obs import event, get_logger
from app.provisioning import TransportUnavailable, provision_pairing
from app.rings import (
    CANCEL_ANSWERED,
    CANCEL_REFUSED,
    CANCEL_UNSUPPORTED,
    TrackedRing,
    ring_bot_flags,
)

router = APIRouter(prefix="/admin", dependencies=[Depends(require_engine_key)])
_log = get_logger("admin")


@router.post("/disconnect")
async def disconnect(req: DisconnectRequest, request: Request):
    ok = await request.app.state.dispatcher.disconnect(req.room_key)
    if not ok:
        raise HTTPException(status_code=404, detail=f"No active bot in room {req.room_key!r}.")
    return {"disconnected": req.room_key}


@router.post("/ring/{agent_id}", response_model=RingResponse)
async def ring(
    agent_id: str, request: Request, req: RingRequest | None = Body(default=None)
) -> RingResponse:
    req = req or RingRequest()
    try:
        agent = get_agent(agent_id)
    except KeyError:
        raise HTTPException(status_code=404, detail=f"Unknown agent_id: {agent_id!r}")

    state = request.app.state
    reg = await state.registry.get_voip(agent_id)
    if reg is None:
        raise HTTPException(
            status_code=404,
            detail=f"No VoIP registration for agent {agent_id!r} — enable "
            "\"Let this agent call me\" in the Conduit app first.",
        )

    payload: dict = {
        "agent_id": reg.app_agent_id,
        "call_id": str(uuid.uuid4()),
        # Receipt channel: the app POSTs the ring's terminal status back here
        # (answered / declined / busy / suppressed_by_focus). Correct absolute
        # URLs behind a TLS-terminating proxy need uvicorn's --proxy-headers.
        "status_url": str(request.url_for("ring_status", agent_id=agent_id)),
    }
    # The user names agents locally, so only a name the app registered is echoed;
    # absent, the keys are omitted and the app rings under its own fallback name.
    if reg.display_name is not None:
        payload["display_name"] = reg.display_name
    if reg.handle is not None:
        payload["handle"] = reg.handle
    # Push values are strings, like every other key. A device that doesn't list
    # the feature rings for its own default, which the ring bot's deadline assumes.
    ring_timeout = req.ring_timeout if "ring_timeout" in reg.push_features else None
    if req.ring_timeout is not None and ring_timeout is None:
        event(_log, "ring.ring_timeout_unsupported", agent=agent_id)
    if ring_timeout is not None:
        payload["ring_timeout"] = str(ring_timeout)
    # Without the feature the ring is exactly one that never asked: no push key,
    # no ring bot, no await-answer.
    preconnect = req.preconnect if "preconnect" in reg.push_features else None
    if req.preconnect is not None and preconnect is None:
        event(_log, "ring.preconnect_unsupported", agent=agent_id)
    if preconnect is not None:
        payload["preconnect"] = preconnect
    ring = TrackedRing(
        call_id=payload["call_id"],
        agent_id=agent_id,
        mode="inline" if req.inline else "pairing",
        preconnect=preconnect,
        ring_timeout=ring_timeout,
    )
    if req.inline:
        # Provision NOW and ride the creds in the push: the bot is dispatched
        # before the user answers. Pairing mode instead defers everything to the
        # app's /connect on answer (or during the ring, with preconnect). Any
        # inline bot ends on a non-answered first receipt; with preconnect it is
        # also a ring bot, with a deadline and a control pipe.
        transport = resolve_transport(agent, req.transport)
        ring_flags = None
        if preconnect is not None:
            ring_flags = ring_bot_flags(
                ring_timeout=ring_timeout, await_answer=preconnect == "media"
            )
        try:
            settings.require(*agent.required_settings)
            creds, room_key = await provision_pairing(
                state, agent.agent_id, transport, ring_flags=ring_flags
            )
        except (TransportUnavailable, MissingSettingError) as e:
            raise HTTPException(status_code=503, detail=str(e))
        payload["room_url"] = creds.connection["room_url"]
        payload["token"] = creds.connection["token"]
        ring.room_key = room_key
        ring.transport = transport
        ring.ring_bot = ring_flags is not None
        ring.awaits_answer = preconnect == "media"

    # Tracked before the push: the app may pair for this ring (preconnect) before
    # APNs has even answered us.
    state.rings.add(ring)
    try:
        result = await _push(state, agent_id, reg, payload)
    except HTTPException:
        state.rings.discard(ring.call_id)
        raise
    event(
        _log,
        "ring.sent",
        agent=agent_id,
        call_id=ring.call_id,
        mode=ring.mode,
        preconnect=ring.preconnect,
        ring_timeout=ring.ring_timeout,
    )

    return RingResponse(
        call_id=payload["call_id"],
        agent_id=reg.app_agent_id,
        display_name=reg.display_name,
        mode=ring.mode,
        ring_timeout=ring.ring_timeout,
        preconnect=ring.preconnect,
        apns_status=result.status,
        apns_id=result.apns_id,
    )


@router.post("/ring/{agent_id}/cancel", response_model=RingCancelResponse)
async def cancel_ring(
    agent_id: str, req: RingCancelRequest, request: Request
) -> RingCancelResponse:
    state = request.app.state
    ring = state.rings.get(req.call_id)
    if ring is None or ring.agent_id != agent_id:
        raise HTTPException(
            status_code=404, detail=f"No ring {req.call_id!r} for agent {agent_id!r}."
        )
    if ring.status is not None:
        # The ring is over (answered, declined, timed out, …): nothing to withdraw.
        raise HTTPException(
            status_code=409,
            detail={"call_id": ring.call_id, "status": ring.status, "reason": "ring ended"},
        )
    if ring.canceled:
        raise HTTPException(
            status_code=409,
            detail={"call_id": ring.call_id, "status": None, "reason": "already canceled"},
        )

    if ring.preconnect == "media" and ring.room_key and await _human_in_room(state, ring):
        # In-band cancel: the phone is in the room with the agent, so the agent
        # leaving IS the cancel. No push, so no flash on the lock screen.
        ended = await _end_ring_bot(state, ring)
        ring.canceled = True
        event(_log, "ring.canceled", call_id=ring.call_id, method="in_band", bot_ended=ended)
        return RingCancelResponse(call_id=ring.call_id, method="in_band", bot_ended=ended)

    reg = await state.registry.get_voip(agent_id)
    if reg is None:
        raise HTTPException(
            status_code=404, detail=f"No VoIP registration for agent {agent_id!r}."
        )
    if "cancel" not in reg.push_features:
        # An app that doesn't list "cancel" would show the push as a brief
        # incoming call while the ring keeps ringing. Nothing is withdrawn, so the
        # ring and its bot are left as they are.
        event(_log, "ring.cancel_unsupported", call_id=ring.call_id, agent=agent_id)
        raise HTTPException(
            status_code=409,
            detail={
                "call_id": ring.call_id,
                "status": None,
                "reason": CANCEL_UNSUPPORTED,
            },
        )
    # A cancel push carries no target_id/agent_id: a 0.1 app then takes it as
    # malformed (a brief flash, then ended) instead of ringing it as a new call.
    payload: dict = {"action": "cancel", "call_id": ring.call_id}
    if reg.display_name is not None:
        payload["display_name"] = reg.display_name
    result = await _push(state, agent_id, reg, payload)
    # The ring's bot (if any) has no one to wait for now, unless the call was
    # answered after all: the push then changes nothing on the phone either.
    ended = await _end_ring_bot(state, ring)
    ring.canceled = True
    event(_log, "ring.canceled", call_id=ring.call_id, method="push", bot_ended=ended)
    return RingCancelResponse(
        call_id=ring.call_id,
        method="push",
        bot_ended=ended,
        apns_status=result.status,
        apns_id=result.apns_id,
    )


async def _end_ring_bot(state, ring: TrackedRing) -> bool:
    """End the bot dispatched for a ring being withdrawn; True if one was ended.

    A ring bot is asked, not signalled: it ends unless it has itself seen the call
    answered (call-answered, or the human joining a ring that waits for no answer),
    which can happen before the answered receipt reaches the engine, and the room
    is full of humans both before and after an answer on a pre-connected ring. A
    refusal raises 409. A bot that can't be asked (no control pipe: a plain inline
    bot; or gone, or silent) is force-ended as before."""
    if not ring.room_key:
        return False
    if ring.ring_bot:
        verdict = await state.dispatcher.cancel_ring_bot(ring.room_key)
        if verdict == CANCEL_REFUSED:
            event(_log, "ring.cancel_refused", call_id=ring.call_id, by="bot")
            raise HTTPException(
                status_code=409,
                detail={"call_id": ring.call_id, "status": "answered", "reason": CANCEL_ANSWERED},
            )
        if verdict is not None:
            return True
    return await state.dispatcher.disconnect(ring.room_key)


async def _push(state, agent_id: str, reg, payload: dict):
    """Send a VoIP push; 503 without APNs config, 502 (and evict a dead token) on
    an APNs rejection."""
    try:
        result = await state.apns.send_voip_push(
            voip_token=reg.voip_token, bundle_id=reg.bundle_id, payload=payload
        )
    except MissingSettingError as e:
        raise HTTPException(status_code=503, detail=str(e))

    if result.status != 200:
        if result.reason == "Unregistered":
            await state.registry.delete_voip(agent_id)
        detail = {"apns_status": result.status, "reason": result.reason}
        if result.hint:
            detail["hint"] = result.hint
        raise HTTPException(status_code=502, detail=detail)
    return result


async def _human_in_room(state, ring: TrackedRing) -> bool:
    service = getattr(state, ring.transport or "", None)
    if service is None:
        return False
    try:
        return await service.human_in_room(ring.room_key)
    except Exception as e:  # can't tell: fall back to the cancel push
        event(_log, "ring.presence_failed", call_id=ring.call_id, error=str(e))
        return False
