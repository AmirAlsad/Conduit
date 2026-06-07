"""Agent registry: ``agent_id -> AgentConfig``.

The seam for future curated default agents — adding one is registering a new
entry here plus a builder in ``bot/runtime.py`` (design §2.1). The bot side maps
the same ids to pipeline builders; this side carries dispatch-time defaults.
"""

from __future__ import annotations

from dataclasses import dataclass

from app.config import settings


@dataclass(frozen=True)
class AgentConfig:
    agent_id: str
    default_transport: str
    description: str


AGENTS: dict[str, AgentConfig] = {
    "loopback": AgentConfig(
        "loopback",
        default_transport="daily",
        description="Audio passthrough; isolates the CallKit↔WebRTC pipe. No model, no keys.",
    ),
    "live": AgentConfig(
        "live",
        default_transport=settings.default_transport,
        description="Reference STT→LLM→TTS agent (Deepgram · Groq · Cartesia) with RTVI.",
    ),
}


def get_agent(agent_id: str) -> AgentConfig:
    try:
        return AGENTS[agent_id]
    except KeyError:
        raise KeyError(agent_id)


def resolve_transport(agent: AgentConfig, requested: str | None) -> str:
    """Requested transport wins; else the agent default; else the engine default."""
    return requested or agent.default_transport or settings.default_transport
