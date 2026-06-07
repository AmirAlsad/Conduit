"""Structured logging for the engine.

One ``event()`` helper emits a single structured line per seam — dispatch
requested/accepted, bot connected/disconnected, webhook received, idempotency
skips, etc. (design §7). These are the second vantage point when correlating
engine behaviour with client logs.
"""

from __future__ import annotations

import sys
from typing import Any

from loguru import logger

from app.config import settings

_configured = False


def setup_logging() -> None:
    """Idempotently configure loguru. Safe to call from both dispatcher and bot."""
    global _configured
    if _configured:
        return
    logger.remove()
    # Default `component` so records from third-party libs (pipecat, uvicorn) that
    # don't bind it still format. bind(component=...) overrides per-record.
    logger.configure(extra={"component": "-"})
    logger.add(
        sys.stderr,
        level=settings.log_level.upper(),
        backtrace=False,
        diagnose=False,
        format=(
            "<green>{time:YYYY-MM-DD HH:mm:ss.SSS}</green> | "
            "<level>{level: <7}</level> | "
            "<cyan>{extra[component]}</cyan> | "
            "<level>{message}</level>"
        ),
    )
    _configured = True


def get_logger(component: str):
    """A logger bound to a component name ('dispatch', 'webhook', 'bot', ...)."""
    setup_logging()
    return logger.bind(component=component)


def event(log, name: str, **fields: Any) -> None:
    """Emit one structured seam event: a stable ``name`` plus key=value fields.

    Example: ``event(log, "dispatch.accepted", room=key, agent=agent_id, pid=pid)``
    """
    suffix = " ".join(f"{k}={v}" for k, v in fields.items())
    log.info(f"{name} {suffix}".rstrip())
