"""Central configuration for the Conduit engine.

One ``Settings`` object, read from the environment, shared by the dispatcher
(``app``) and the bot subprocess (``bot``). Bot subprocesses inherit the
dispatcher's environment, so the same settings load on both sides.

Every secret is optional (``None`` default) so partial environments work: you
can run just the loopback bot with only Daily creds, without LiveKit/Groq keys
present. Each feature validates the keys it actually needs at point of use via
``require()``.
"""

from __future__ import annotations

from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class MissingSettingError(RuntimeError):
    """A feature was used without the setting(s) it needs. Raised by ``require()``
    so callers can catch it and return a clean error (e.g. 503) instead of a 500."""


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env", env_file_encoding="utf-8", extra="ignore"
    )

    # --- Dispatcher auth ---
    # Bearer token required on /connect, /credentials, /admin/*. Spawning bots is
    # billable, so an unauthenticated dispatcher on a public URL is a cost/abuse vector.
    engine_api_key: str | None = None

    # --- Daily Cloud ---
    daily_api_key: str | None = None
    daily_api_url: str = "https://api.daily.co/v1"
    # Base-64 HMAC secret used to sign/verify the participant-joined webhook. You set
    # it here; the registration script registers it with Daily as the webhook `hmac`
    # (bring-your-own), so what Daily signs with always matches what we verify with.
    daily_webhook_secret: str | None = None

    # --- LiveKit Cloud ---
    livekit_api_key: str | None = None
    livekit_api_secret: str | None = None
    livekit_url: str | None = None  # wss://<project>.livekit.cloud

    # --- live bot model stack (Deepgram STT · Groq LLM · Cartesia TTS) ---
    deepgram_api_key: str | None = None
    groq_api_key: str | None = None
    groq_model: str = "llama-3.3-70b-versatile"
    cartesia_api_key: str | None = None
    # Default Cartesia voice ("British Reading Lady"), matches upstream examples.
    cartesia_voice_id: str = "71a7ad14-091c-4e8e-a314-022ece01c121"

    # --- Behaviour knobs ---
    bot_name: str = "Conduit Bot"
    default_transport: str = "daily"  # "daily" | "livekit"

    # Dev-runner convenience: which agent `python -m bot.bot` (no dispatch args) runs.
    conduit_agent: str = "loopback"
    # loopback: synthesize bot-speaking RTVI state while echoing so the client's glow
    # can be exercised without a model. False = the truly pure pipe.
    loopback_bot_speaking: bool = True
    loopback_rms_threshold: float = 500.0

    # Endpointing delay (design §2.2). Silero VAD trailing-silence before a turn is
    # considered ended. Default 0.2 (Smart-Turn's trained value); raise it to give a
    # thinking-partner more silence tolerance, at some latency cost.
    vad_stop_secs: float = 0.2

    # Human-absent grace window (design §2.5). On a dropped connection the bot stays
    # this long so a reconnecting client resumes mid-conversation. Must be >= the
    # client's total reconnect-with-backoff budget. SHARED CONSTANT with the client team.
    human_absent_grace_secs: float = 60.0

    # Backstop so a wedged/forgotten bot can't bill forever. The thinking-partner use
    # case has long silences, so this is generous; teardown is normally driven by the
    # grace timer + the explicit end-call signal, not this.
    pipeline_idle_timeout_secs: float = 1800.0

    # Token TTLs. Pairing tokens are born per-call (short); direct tokens are pasted
    # into the app once and must outlive many calls (long). Expiry gates only the
    # *initial* connect, never reconnects (design §4).
    pairing_token_ttl_secs: int = 300  # 5 min
    direct_token_ttl_secs: int = 60 * 60 * 24 * 30  # 30 days
    # Daily room expirations (rooms auto-close at exp). Pairing rooms are ephemeral;
    # direct rooms are long-lived.
    pairing_room_exp_secs: int = 60 * 60  # 1 h safety cap on a pairing room
    direct_room_exp_secs: int = 60 * 60 * 24 * 90  # 90 days

    # --- Deployment / ops ---
    public_base_url: str | None = None  # for webhook registration at deploy time
    log_level: str = "INFO"

    def require(self, *names: str) -> None:
        """Raise a clear error if any named setting is unset. Call at the point a
        feature needs a key, so partial environments fail loudly and specifically."""
        missing = [n for n in names if not getattr(self, n)]
        if missing:
            raise MissingSettingError(
                f"Missing required setting(s): {', '.join(missing)}. "
                "Set them in the environment or .env."
            )


@lru_cache
def get_settings() -> Settings:
    return Settings()


settings = get_settings()
