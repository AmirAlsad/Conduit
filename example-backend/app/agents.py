"""Agent registry: ``agent_id -> AgentConfig``.

The seam for future curated default agents — adding one is registering a new
entry here plus a builder in ``bot/runtime.py`` (design §2.1). The bot side maps
the same ids to pipeline builders; this side carries dispatch-time defaults.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from app.config import settings


@dataclass(frozen=True)
class AgentConfig:
    agent_id: str
    default_transport: str
    description: str
    # Settings the agent's pipeline needs (validated by the dispatcher BEFORE
    # spawning, so a missing key returns a clean 503 instead of minting creds for a
    # bot that crashes on launch — which would leave the client connected to silence).
    required_settings: tuple[str, ...] = field(default_factory=tuple)


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
        # STT + LLM keys, plus whichever TTS provider TTS_PROVIDER selects (deduped).
        required_settings=tuple(
            dict.fromkeys(
                (
                    "deepgram_api_key",
                    "groq_api_key",
                    {
                        "cartesia": "cartesia_api_key",
                        "deepgram": "deepgram_api_key",
                        "groq": "groq_api_key",
                    }.get(settings.tts_provider.lower(), "cartesia_api_key"),
                )
            )
        ),
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
