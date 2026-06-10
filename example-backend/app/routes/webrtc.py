"""SmallWebRTC signaling endpoints.

- POST  /webrtc/{agent_id}/offer — SDP offer in, SDP answer out; spawns the
  in-process bot for new peer connections.
- PATCH /webrtc/{agent_id}/offer — trickle-ICE candidates for an existing peer
  connection (the iOS client PATCHes the same URL it POSTed, same headers).

Auth differs from the other billable routes: the bearer may be either the
engine key (manual/direct use) or a short-lived offer token minted by
/connect/{agent_id} during pairing — so the key itself never has to ride the
offer leg.
"""

from __future__ import annotations

import hmac

from fastapi import APIRouter, Header, HTTPException, Request, status
from pydantic import BaseModel

from app.agents import get_agent
from app.config import MissingSettingError, settings

router = APIRouter()


class OfferRequest(BaseModel):
    sdp: str
    type: str
    pc_id: str | None = None
    restart_pc: bool | None = None


class IceCandidateModel(BaseModel):
    candidate: str
    sdp_mid: str
    sdp_mline_index: int


class PatchRequest(BaseModel):
    pc_id: str
    candidates: list[IceCandidateModel]


def _authorize(request: Request, agent_id: str, authorization: str) -> None:
    expected = f"Bearer {settings.engine_api_key}"
    if hmac.compare_digest(authorization, expected):
        return
    service = getattr(request.app.state, "smallwebrtc", None)
    presented = authorization.removeprefix("Bearer ")
    if service is not None and service.validate_token(presented, agent_id):
        return
    raise HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Invalid or missing bearer token.",
        headers={"WWW-Authenticate": "Bearer"},
    )


def _validated_agent(agent_id: str):
    try:
        agent = get_agent(agent_id)
    except KeyError:
        raise HTTPException(status_code=404, detail=f"Unknown agent_id: {agent_id!r}")
    try:
        # Same fail-clean rule as /connect: never accept an offer for a bot that
        # would crash on missing model keys, leaving the peer connected to silence.
        settings.require(*agent.required_settings)
    except MissingSettingError as e:
        raise HTTPException(status_code=503, detail=str(e))
    return agent


@router.post("/webrtc/{agent_id}/offer")
async def webrtc_offer(
    agent_id: str,
    req: OfferRequest,
    request: Request,
    authorization: str = Header(default=""),
) -> dict:
    _authorize(request, agent_id, authorization)
    agent = _validated_agent(agent_id)
    answer = await request.app.state.smallwebrtc.handle_offer(
        agent.agent_id, req.model_dump()
    )
    if answer is None:
        raise HTTPException(status_code=500, detail="No SDP answer produced.")
    return answer


@router.patch("/webrtc/{agent_id}/offer")
async def webrtc_patch(
    agent_id: str,
    req: PatchRequest,
    request: Request,
    authorization: str = Header(default=""),
) -> dict:
    _authorize(request, agent_id, authorization)
    _validated_agent(agent_id)
    await request.app.state.smallwebrtc.handle_patch(req.model_dump())
    return {"status": "ok"}
