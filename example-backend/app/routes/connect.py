"""Credential endpoints.

- POST /connect      — pairing: create creds, dispatch the bot now, return creds.
- POST /credentials  — direct provision: create stable creds, register the room,
                       return creds (dispatch happens later via webhook).
- POST /connect/{agent_id} and /credentials/{agent_id} — same, but the URL names
  the agent ("the endpoint identifies the agent" — the Conduit app never sends an
  agent_id, so each agent gets its own pairing endpoint).

All require the engine bearer token and converge on the provisioning core.
"""

from __future__ import annotations

from fastapi import APIRouter, Body, Depends, HTTPException, Request

from app.agents import get_agent, resolve_transport
from app.auth import require_engine_key
from app.config import MissingSettingError, settings
from app.models import ConnectionPayload, ConnectRequest
from app.obs import event, get_logger
from app.provisioning import (
    TransportUnavailable,
    provision_direct,
    provision_pairing,
)
from app.rings import RING_ENDED, TrackedRing, ring_bot_flags

_log = get_logger("connect")

router = APIRouter(dependencies=[Depends(require_engine_key)])


def _own_ring(state, call_id: str, agent_id: str) -> TrackedRing | None:
    ring = state.rings.get(call_id)
    return ring if ring is not None and ring.agent_id == agent_id else None


def _ring_over(ring: TrackedRing | None) -> HTTPException | None:
    """409 for a ring that already ended without being answered (a receipt other
    than "answered", or our own cancel): nobody is coming, so no bot is wanted. The
    phone treats a failed pre-connect as just that and the ring stays as it was.
    An answered ring is not over; the call is live and still needs its room."""
    if ring is None or not (ring.canceled or ring.status not in (None, "answered")):
        return None
    return HTTPException(
        status_code=409,
        detail={
            "call_id": ring.call_id,
            "status": ring.status or "canceled",
            "reason": RING_ENDED,
        },
    )


async def _provision(request: Request, req: ConnectRequest, *, direct: bool) -> ConnectionPayload:
    try:
        agent = get_agent(req.agent_id)
    except KeyError:
        raise HTTPException(status_code=404, detail=f"Unknown agent_id: {req.agent_id!r}")
    transport = resolve_transport(agent, req.transport)
    try:
        # Validate the agent's model keys up front. Without this, requesting `live`
        # with missing provider keys would mint valid creds, then the bot would crash
        # on launch — leaving the client connected to a silent (and, for pairing,
        # promptly deleted) room. Fail clean with 503 instead.
        settings.require(*agent.required_settings)
        if direct:
            return await provision_direct(request.app.state, agent.agent_id, transport)
        state = request.app.state
        ring_flags = None
        if req.ring is not None:
            # The app is pairing while the phone still rings (preconnect): the bot
            # gets the ring deadline, and if the app joins before the answer, its
            # joining is not the answer.
            tracked = _own_ring(state, req.ring.call_id, agent.agent_id)
            if over := _ring_over(tracked):
                event(_log, "connect.ring_over", call_id=req.ring.call_id, status=tracked.status)
                raise over
            ring_flags = ring_bot_flags(
                ring_timeout=tracked.ring_timeout if tracked else None,
                joins_before_answer=req.ring.joins_before_answer,
            )
        # base_url backs smallwebrtc's offer URL when PUBLIC_BASE_URL is unset:
        # the device reached us at this address, so the offer URL at the same
        # host is correct by construction (the LAN case).
        payload, room_key = await provision_pairing(
            state,
            agent.agent_id,
            transport,
            base_url=str(request.base_url),
            ring_flags=ring_flags,
            # A client that sends call-connected is greeted when it arrives.
            await_connected=req.sends_call_connected,
        )
        if req.ring is not None and room_key is not None:
            # A receipt may have landed while the room was being made: it found no
            # bot to end, so the one just dispatched must go.
            if over := _ring_over(_own_ring(state, req.ring.call_id, agent.agent_id)):
                await state.dispatcher.disconnect(room_key)
                event(_log, "connect.ring_over", call_id=req.ring.call_id, bot_ended=True)
                raise over
            ring = state.rings.attach_bot(
                req.ring.call_id,
                agent.agent_id,
                room_key=room_key,
                transport=transport,
                joins_before_answer=req.ring.joins_before_answer,
            )
            if ring is not None and ring.status == "answered":
                # The receipt came first, so nothing will relay it to this bot.
                await state.dispatcher.send_control(room_key, "answered")
            event(
                _log,
                "connect.ring_bot",
                call_id=req.ring.call_id,
                room=room_key,
                joins_before_answer=req.ring.joins_before_answer,
                await_connected=req.sends_call_connected,
            )
        return payload
    except (TransportUnavailable, MissingSettingError) as e:
        raise HTTPException(status_code=503, detail=str(e))


@router.post("/connect", response_model=ConnectionPayload)
async def connect(req: ConnectRequest, request: Request) -> ConnectionPayload:
    """Pairing: bot is dispatched before/just as the app joins."""
    return await _provision(request, req, direct=False)


@router.post("/credentials", response_model=ConnectionPayload)
async def credentials(req: ConnectRequest, request: Request) -> ConnectionPayload:
    """Direct provision: called once; result pasted into the app's add/edit sheet."""
    return await _provision(request, req, direct=True)


def _with_path_agent(req: ConnectRequest | None, agent_id: str) -> ConnectRequest:
    # The path names the agent; it wins over any body agent_id. Body is optional
    # so a bare `curl -X POST .../connect/live` works without `-d`.
    return (req or ConnectRequest()).model_copy(update={"agent_id": agent_id})


@router.post("/connect/{agent_id}", response_model=ConnectionPayload)
async def connect_agent(
    agent_id: str, request: Request, req: ConnectRequest | None = Body(default=None)
) -> ConnectionPayload:
    """Pairing via a per-agent endpoint — what the Conduit app points at."""
    return await _provision(request, _with_path_agent(req, agent_id), direct=False)


@router.post("/credentials/{agent_id}", response_model=ConnectionPayload)
async def credentials_agent(
    agent_id: str, request: Request, req: ConnectRequest | None = Body(default=None)
) -> ConnectionPayload:
    """Direct provision via a per-agent endpoint (see scripts/provision.py)."""
    return await _provision(request, _with_path_agent(req, agent_id), direct=True)
