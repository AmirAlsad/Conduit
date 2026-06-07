"""Bearer-token auth for the billable endpoints.

``/connect``, ``/credentials``, and ``/admin/*`` mint credentials and spawn
billable bots, so they require ``ENGINE_API_KEY`` (design §2.1). Webhooks are the
exception — they authenticate by signature, since the caller is the SFU.
"""

from __future__ import annotations

import hmac

from fastapi import Header, HTTPException, status

from app.config import settings


async def require_engine_key(authorization: str = Header(default="")) -> None:
    # engine_api_key presence is guaranteed at startup (app.main lifespan fails fast
    # if unset), so we never 500 here — just compare and 401 on mismatch.
    expected = f"Bearer {settings.engine_api_key}"
    # Constant-time compare so the token can't be recovered by timing.
    if not hmac.compare_digest(authorization, expected):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or missing bearer token.",
            headers={"WWW-Authenticate": "Bearer"},
        )
