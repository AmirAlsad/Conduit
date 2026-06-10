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
        # base_url backs smallwebrtc's offer URL when PUBLIC_BASE_URL is unset:
        # the device reached us at this address, so the offer URL at the same
        # host is correct by construction (the LAN case).
        return await provision_pairing(
            request.app.state, agent.agent_id, transport, base_url=str(request.base_url)
        )
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
