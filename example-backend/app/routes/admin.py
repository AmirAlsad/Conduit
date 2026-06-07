"""Admin endpoint: force-disconnect a bot from a room.

The clean way to simulate a mid-call drop so the client's reconnection-with-
spoken-state path can be tested deterministically (design §2.1, §6 Layer 2).
"""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Request

from app.auth import require_engine_key
from app.models import DisconnectRequest

router = APIRouter(prefix="/admin", dependencies=[Depends(require_engine_key)])


@router.post("/disconnect")
async def disconnect(req: DisconnectRequest, request: Request):
    ok = await request.app.state.dispatcher.disconnect(req.room_key)
    if not ok:
        raise HTTPException(status_code=404, detail=f"No active bot in room {req.room_key!r}.")
    return {"disconnected": req.room_key}
