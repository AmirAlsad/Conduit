"""Inbound-call token registration (docs/INBOUND_CALLS.md §1).

The Conduit app POSTs its device VoIP token here when the user enables "Let this
agent call me" (and on every app launch thereafter). The stored token is what
/admin/ring sends the push to. Latest registration per agent wins — the token is
per-install, app-wide.
"""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Request

from app.agents import get_agent
from app.auth import require_engine_key
from app.models import VoipRegisterRequest
from app.registry import VoipRegistration

router = APIRouter(prefix="/inbound", dependencies=[Depends(require_engine_key)])


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
