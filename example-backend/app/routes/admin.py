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
a ring_timeout or a preconnect, and would show a cancel push as a brief incoming
call. A "media" preconnect also needs the registration to list the
"call-connected" call signal: the device then joins before the answer, and only
call-connected tells the bot the user is on the line. Without it the ring asks
for "credentials" instead. A ring that names no preconnect asks for the best
tier the registration takes; "none" asks for none.

Agent-first ringing: so the agent is ready when the user picks up, a ring whose
bot starts before the push (inline; and a pre-connected pairing ring, whose room
and bot are prepared now for the app's credential request during the ring)
waits until the bot has joined the room (its "joined" line on the control
pipe), at most RING_BOT_WAIT_SECS, then pushes. The ring is tracked during the
wait: a cancel or a receipt then means it is never pushed.
"""

from __future__ import annotations

import asyncio
import time
import uuid

from fastapi import APIRouter, Body, Depends, HTTPException, Request

from app.agents import get_agent, resolve_transport
from app.auth import require_engine_key
from app.config import MissingSettingError, settings
from app.models import (
    CALL_CONNECTED,
    DisconnectRequest,
    RingCancelRequest,
    RingCancelResponse,
    RingRequest,
    RingResponse,
)
from app.dispatch import BOT_JOINED
from app.obs import event, get_logger
from app.provisioning import TransportUnavailable, provision_pairing
from app.rings import (
    CANCEL_ANSWERED,
    CANCEL_REFUSED,
    CANCEL_UNSUPPORTED,
    RING_ENDED,
    TrackedRing,
    ring_bot_flags,
    ring_deadline_secs,
)

# The bot-wait outcome when the ring ended (a cancel or a receipt) during the wait.
_WITHDRAWN = "withdrawn"

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
        # (RING_STATUSES: answered / declined / busy / suppressed_by_focus /
        # unanswered / canceled, and any a newer app adds). Correct absolute
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
    sends_call_connected = CALL_CONNECTED in reg.call_signals
    preconnect = _preconnect_tier(agent_id, req.preconnect, reg, sends_call_connected)
    if preconnect is not None:
        payload["preconnect"] = preconnect
    ring = TrackedRing(
        call_id=payload["call_id"],
        agent_id=agent_id,
        mode="inline" if req.inline else "pairing",
        preconnect=preconnect,
        ring_timeout=ring_timeout,
    )
    wait_secs = settings.ring_bot_wait_secs if req.wait_for_bot else 0.0
    # The room made at ring time must be on the transport the phone's agent calls
    # over, or the phone's own request finds it unfit and starts a cold one.
    transport = req.transport or reg.transport
    if transport is None:
        event(_log, "ring.transport_unknown", agent=agent_id, inline=req.inline)
    if req.inline:
        # The push must carry a room: without the phone's transport, the agent's
        # default, as before the registration named one.
        transport = transport or resolve_transport(agent, None)
        # Provision NOW and ride the creds in the push: the bot is dispatched
        # before the user answers. Any inline bot ends on a non-answered first
        # receipt; with preconnect it is also a ring bot, with a deadline and a
        # control pipe.
        ring_flags = None
        # A plain inline bot has no ring deadline, and the phone joins it only
        # after the answer: it waits for the phone as long as the ring can last.
        join_timeout = ring_deadline_secs(ring_timeout) + wait_secs
        if preconnect is not None:
            ring_flags = ring_bot_flags(
                ring_timeout=ring_timeout,
                joins_before_answer=preconnect == "media",
                push_wait_secs=wait_secs,
            )
            # A ring bot's deadline covers the ring; after the answer, the default.
            join_timeout = None
        try:
            settings.require(*agent.required_settings)
            creds, room_key = await provision_pairing(
                state,
                agent.agent_id,
                transport,
                # A smallwebrtc offer URL on the address this ring was sent
                # through, like the push's status_url.
                base_url=str(request.base_url),
                # The app reuses inline credentials for every attempt of the
                # call, reconnects included: the token must outlive the call,
                # not just the ring (a pairing room's whole lifetime).
                token_ttl_secs=settings.pairing_room_exp_secs,
                join_timeout_secs=join_timeout,
                ring_flags=ring_flags,
                # The bot starts before the app asks for anything, so only the
                # registration says whether the app sends call-connected.
                await_connected=sends_call_connected,
                report_joined=wait_secs > 0,
            )
        except (TransportUnavailable, MissingSettingError) as e:
            raise HTTPException(status_code=503, detail=str(e))
        payload["room_url"] = creds.connection["room_url"]
        payload["token"] = creds.connection["token"]
        ring.room_key = room_key
        ring.transport = transport
        ring.ring_bot = ring_flags is not None
        ring.joins_before_answer = preconnect == "media"
    elif preconnect is not None and wait_secs > 0 and transport is not None:
        # The app will ask for credentials during the ring (with the ring's
        # call_id), so its room and agent can be made now. Without preconnect the
        # app asks only after the answer, with nothing to match a prepared room to;
        # without the phone's transport, a room made now could be the wrong kind,
        # so nothing is made and nothing waited for (the phone's request makes it).
        await _prepare(state, agent, ring, transport, wait_secs, sends_call_connected)

    # Tracked before the push: the app may pair for this ring (preconnect) before
    # APNs has even answered us, and a cancel or receipt can find it while we
    # wait for its bot.
    state.rings.add(ring)
    ring.awaiting_push = True
    bot_in_room = bot_wait_secs = None
    if ring.room_key is not None and wait_secs > 0:
        event(
            _log,
            "ring.waiting_for_bot",
            agent=agent_id,
            call_id=ring.call_id,
            room=ring.room_key,
            bound_secs=wait_secs,
        )
        outcome, bot_wait_secs = await _await_bot(state, ring, wait_secs)
        bot_in_room = outcome == BOT_JOINED
        event(
            _log,
            "ring.bot_wait",
            call_id=ring.call_id,
            room=ring.room_key,
            outcome=outcome,
            waited_secs=bot_wait_secs,
        )
    ring.awaiting_push = False
    if ring.canceled or ring.status is not None:
        await _withdrawn_before_push(state, ring)
    try:
        result = await _push(state, agent_id, reg, payload)
    except HTTPException:
        state.rings.discard(ring.call_id)
        if ring.room_key:
            # The ring never reached the phone: nobody will come to this bot.
            await state.dispatcher.disconnect(ring.room_key)
        raise
    event(
        _log,
        "ring.sent",
        agent=agent_id,
        call_id=ring.call_id,
        mode=ring.mode,
        preconnect=ring.preconnect,
        ring_timeout=ring.ring_timeout,
        bot_in_room=bot_in_room,
        bot_wait_secs=bot_wait_secs,
        transport=ring.transport,
    )

    return RingResponse(
        call_id=payload["call_id"],
        agent_id=reg.app_agent_id,
        display_name=reg.display_name,
        mode=ring.mode,
        ring_timeout=ring.ring_timeout,
        preconnect=ring.preconnect,
        bot_in_room=bot_in_room,
        bot_wait_secs=bot_wait_secs,
        transport=ring.transport,
        apns_status=result.status,
        apns_id=result.apns_id,
    )


def _preconnect_tier(agent_id: str, requested: str | None, reg, sends_call_connected: bool):
    """The preconnect the push carries. Without the push feature the ring is
    exactly one that never asked: no push key, no ring bot. Unrequested, the best
    the registration takes; "media" needs call-connected."""
    if requested == "none":
        return None
    if "preconnect" not in reg.push_features:
        if requested is not None:
            event(_log, "ring.preconnect_unsupported", agent=agent_id)
        return None
    if requested is None:
        return "media" if sends_call_connected else "credentials"
    if requested == "media" and not sends_call_connected:
        event(_log, "ring.preconnect_media_needs_call_connected", agent=agent_id)
        return "credentials"
    return requested


async def _prepare(
    state, agent, ring: TrackedRing, transport: str, wait_secs: float, sends_call_connected: bool
) -> None:
    """Make a pre-connected pairing ring's room and ring bot before the push; the
    app's credential request for the ring then takes them (app/routes/connect.py).
    Best effort: when it fails, the ring goes out as before and that request
    provisions. ``transport`` is the phone's (the request's, else its registration's).
    SmallWebRTC has no room to prepare: its bot starts at the phone's offer."""
    if transport == "smallwebrtc":
        return
    flags = ring_bot_flags(
        ring_timeout=ring.ring_timeout,
        joins_before_answer=ring.preconnect == "media",
        push_wait_secs=wait_secs,
    )
    try:
        settings.require(*agent.required_settings)
        creds, room_key = await provision_pairing(
            state,
            agent.agent_id,
            transport,
            ring_flags=flags,
            await_connected=sends_call_connected,
            report_joined=True,
        )
    except Exception as e:
        event(_log, "ring.prepare_failed", call_id=ring.call_id, transport=transport, error=repr(e))
        return
    ring.room_key = room_key
    ring.transport = transport
    ring.ring_bot = True
    ring.joins_before_answer = ring.preconnect == "media"
    ring.prepared = creds
    ring.prepared_await_connected = sends_call_connected
    event(_log, "ring.prepared", call_id=ring.call_id, room=room_key, transport=transport)


async def _await_bot(state, ring: TrackedRing, timeout: float) -> tuple[str, float]:
    """Wait for the ring's bot to join its room, at most ``timeout``, or until the
    ring ends. Returns the outcome and the seconds waited."""
    started = time.monotonic()
    joined = asyncio.create_task(state.dispatcher.wait_joined(ring.room_key, timeout))
    ended = asyncio.create_task(ring.ended.wait())
    try:
        await asyncio.wait({joined, ended}, return_when=asyncio.FIRST_COMPLETED)
    finally:
        joined.cancel()
        ended.cancel()
    waited = round(time.monotonic() - started, 3)
    if joined.done() and not joined.cancelled():
        return joined.result(), waited
    return _WITHDRAWN, waited


async def _withdrawn_before_push(state, ring: TrackedRing) -> None:
    """The ring was canceled, or got a receipt, while it waited for its bot: never
    push it (409). The cancel or the receipt has ended the bot, except an
    "answered" receipt for an inline ring, which no phone could have sent."""
    if ring.status == "answered" and ring.mode == "inline" and ring.room_key and not ring.canceled:
        await state.dispatcher.disconnect(ring.room_key)
    event(
        _log,
        "ring.withdrawn_before_push",
        call_id=ring.call_id,
        status=ring.status,
        canceled=ring.canceled,
    )
    raise HTTPException(
        status_code=409,
        detail={"call_id": ring.call_id, "status": ring.status or "canceled", "reason": RING_ENDED},
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
            detail={"call_id": ring.call_id, "status": ring.status, "reason": RING_ENDED},
        )
    if ring.canceled:
        raise HTTPException(
            status_code=409,
            detail={"call_id": ring.call_id, "status": None, "reason": "already canceled"},
        )

    if ring.awaiting_push:
        # Still waiting for its bot: the push never goes out, and the bot (no
        # answer possible yet) is simply ended.
        ring.canceled = True
        ring.ended.set()
        ended = await state.dispatcher.disconnect(ring.room_key) if ring.room_key else False
        event(_log, "ring.canceled", call_id=ring.call_id, method="before_push", bot_ended=ended)
        return RingCancelResponse(call_id=ring.call_id, method="before_push", bot_ended=ended)

    if ring.preconnect == "media" and ring.room_key and await _human_in_room(state, ring):
        # In-band cancel: the phone is in the room with the agent, so the agent
        # leaving IS the cancel. No push, so no flash on the lock screen.
        ended = await _end_ring_bot(state, ring)
        ring.canceled = True
        ring.ended.set()
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
    ring.ended.set()
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
    answered (call-connected, or the human joining a ring it joins only after the
    answer),
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
