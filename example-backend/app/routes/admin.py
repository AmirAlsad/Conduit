"""Admin endpoints: force-disconnect a bot, and ring a registered device.

- POST /admin/disconnect — the clean way to simulate a mid-call drop so the
  client's reconnection-with-spoken-state path can be tested deterministically
  (design §2.1, §6 Layer 2).
- POST /admin/ring/{agent_id} — agent-initiated inbound call: send a VoIP push
  to the device that registered via /inbound/register (docs/INBOUND_CALLS.md §2).
"""

from __future__ import annotations

import uuid

from fastapi import APIRouter, Body, Depends, HTTPException, Request

from app.agents import get_agent, resolve_transport
from app.auth import require_engine_key
from app.config import MissingSettingError, settings
from app.models import DisconnectRequest, RingRequest, RingResponse
from app.provisioning import TransportUnavailable, provision_pairing

router = APIRouter(prefix="/admin", dependencies=[Depends(require_engine_key)])


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

    payload: dict = {"agent_id": reg.app_agent_id, "call_id": str(uuid.uuid4())}
    mode = "pairing"
    if req.inline:
        # Provision NOW and ride the creds in the push: the bot is dispatched
        # before the user answers (and idles on a decline until timeouts reap it).
        # Pairing mode instead defers everything to the app's /connect on answer.
        mode = "inline"
        try:
            settings.require(*agent.required_settings)
            creds = await provision_pairing(
                state, agent.agent_id, resolve_transport(agent, req.transport)
            )
        except (TransportUnavailable, MissingSettingError) as e:
            raise HTTPException(status_code=503, detail=str(e))
        payload["room_url"] = creds.connection["room_url"]
        payload["token"] = creds.connection["token"]

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

    return RingResponse(
        call_id=payload["call_id"],
        agent_id=reg.app_agent_id,
        mode=mode,
        apns_status=result.status,
        apns_id=result.apns_id,
    )
