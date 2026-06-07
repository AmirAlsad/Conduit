"""Credential endpoints.

- POST /connect      — pairing: create creds, dispatch the bot now, return creds.
- POST /credentials  — direct provision: create stable creds, register the room,
                       return creds (dispatch happens later via webhook).

Both require the engine bearer token and converge on the provisioning core.
"""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Request

from app.agents import get_agent, resolve_transport
from app.auth import require_engine_key
from app.config import MissingSettingError, settings
from app.models import ConnectionPayload, ConnectRequest
from app.provisioning import (
    TransportUnavailable,
    provision_direct,
    provision_pairing,
)

router = APIRouter(dependencies=[Depends(require_engine_key)])


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
        return await provision_pairing(request.app.state, agent.agent_id, transport)
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
