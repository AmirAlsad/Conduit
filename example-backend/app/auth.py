"""Bearer-token auth for the billable endpoints.

``/connect``, ``/credentials``, ``/inbound/*`` and ``/admin/*`` require
``ENGINE_API_KEY`` (design §2.1): they mint credentials, spawn billable bots and
ring the phone. It is one key for the phone and the operator alike (see the
README's Security section). Webhooks are the exception — they authenticate by
signature, since the caller is the SFU; ``/webrtc/*`` also takes a short-lived
offer token (app/routes/webrtc.py).
"""

from __future__ import annotations

import hmac

from fastapi import Header, HTTPException, status

from app.config import settings


async def require_engine_key(authorization: str = Header(default="")) -> None:
    # A real engine_api_key is guaranteed at startup (app.main lifespan refuses an
    # empty or placeholder one), so we never 500 here — just compare and 401.
    expected = f"Bearer {settings.engine_api_key}"
    # Constant-time compare so the token can't be recovered by timing.
    if not hmac.compare_digest(authorization, expected):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or missing bearer token.",
            headers={"WWW-Authenticate": "Bearer"},
        )
