"""Inbound-call token registration and ring-status receipts (docs/INBOUND_CALLS.md).

The Conduit app POSTs its device VoIP token here when the user enables "Let this
agent call me" (and on every app launch thereafter). The stored token is what
/admin/ring sends the push to. Latest registration per agent wins — the token is
per-install, app-wide.

/inbound/status is the receipt channel: each ring's push carries a status_url
pointing here, and the app reports how the ring ended (answered / declined /
busy / suppressed_by_focus) — so an agent that really needed to reach the user
knows whether the ring landed. The engine just logs the receipt.
"""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Request

from app.agents import get_agent
from app.auth import require_engine_key
from app.models import RingStatusRequest, VoipRegisterRequest
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
async def ring_status(agent_id: str, req: RingStatusRequest):
    try:
        get_agent(agent_id)
    except KeyError:
        raise HTTPException(status_code=404, detail=f"Unknown agent_id: {agent_id!r}")
    event(_log, "inbound.ring_status", agent=agent_id, call_id=req.call_id, status=req.status)
    return {"ok": True}
