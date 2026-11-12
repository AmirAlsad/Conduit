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

import os
from functools import lru_cache

import certifi
from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict

# Make TLS verification work regardless of the OS trust store. The python.org / uv
# Python builds (notably on macOS) ship an *empty* default CA set, so every outbound
# TLS connection in this process — Daily REST (aiohttp), Deepgram/Cartesia
# (websockets), Groq (httpx), LiveKit — fails with "unable to get local issuer
# certificate". Pointing the process's default SSL context at certifi's bundle fixes
# all of them at once. config.py is imported early by both the dispatcher and every
# bot subprocess, so this runs before any connection. setdefault so a deploy that
# sets its own bundle (e.g. a corporate CA) still wins; on Linux the system store
# already works, and certifi is a valid superset there too.
os.environ.setdefault("SSL_CERT_FILE", certifi.where())


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
    # TTS provider for the `live` bot: "cartesia" (default) | "deepgram" | "groq".
    # Each uses that provider's existing key (Cartesia→CARTESIA_API_KEY, Deepgram
    # Aura→DEEPGRAM_API_KEY, Groq PlayAI→GROQ_API_KEY).
    tts_provider: str = "cartesia"

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

    # Grace window used instead of human_absent_grace_secs when the human leaves
    # while the call is on hold (a cellular call can take the data path with it,
    # and a hold lasts longer than a tunnel).
    held_grace_secs: float = 600.0

    # Ring deadline for bots dispatched for a pre-connected ring (docs/INBOUND_CALLS.md):
    # a bot that hears no answer within the ring's timeout plus this margin ends.
    # ring_timeout_secs is the ring length ASSUMED when the push carried no
    # ring_timeout (the request set none, or the device doesn't list the feature):
    # the phone then rings for its own configured timeout, 60 s by default, which
    # an app can change or turn off. Set this to match your app's, or always send
    # ring_timeout (a firm bound: the app clamps it to [10 s, its own timeout]).
    ring_timeout_secs: int = Field(default=60, gt=0)
    ring_deadline_margin_secs: float = 15.0
    # Agent-first ringing: a ring that starts its bot before the push (inline, and
    # pre-connected pairing rings) sends the push once the bot has joined the room,
    # or after this many seconds without it, so a slow or broken bot never blocks
    # a ring (observed joins: 2 to 7 s). Its ring bot's deadline is lengthened by
    # the same amount. 0 turns agent-first ringing off: every ring is pushed at
    # once, as a ring with "wait_for_bot": false is.
    ring_bot_wait_secs: float = Field(default=8.0, ge=0)
    # A pre-connected pairing ring answered before the phone took its prepared room:
    # the phone sends the "answered" receipt at the answer, and its credential
    # request for the ring may still be on the way (most likely on a cold launch
    # answered quickly). The prepared bot is kept this long for that request before
    # it is ended as unclaimed.
    prepared_claim_grace_secs: float = Field(default=10.0, ge=0)
    # A bot for a client that sends call-connected greets when it arrives. The
    # fallback for a lost one: once the bot knows the user answered (at once for an
    # ordinary call; for a ring, the "answered" receipt, or the device joining a
    # ring it joins only after the answer) and the device is in the room, it
    # greets anyway this long after the later of the two. It must outlast the
    # app's own sequence after it joins (its minimum connecting time, about 2.6 s
    # in Conduit, and its "Connected", which the engine bounds at 5 s), and the
    # push contract asks for 5 seconds or more.
    call_connected_grace_secs: float = Field(default=10.0, ge=5.0)

    # Token TTLs. Pairing tokens are born per-call (short); direct tokens are pasted
    # into the app once and must outlive many calls (long). Expiry gates only the
    # *initial* connect, never reconnects (design §4).
    pairing_token_ttl_secs: int = 300  # 5 min
    direct_token_ttl_secs: int = 60 * 60 * 24 * 30  # 30 days
    # Daily room expirations (rooms auto-close at exp). Pairing rooms are ephemeral;
    # direct rooms are long-lived.
    pairing_room_exp_secs: int = 60 * 60  # 1 h safety cap on a pairing room
    direct_room_exp_secs: int = 60 * 60 * 24 * 90  # 90 days

    # --- Registry persistence ---
    # SQLite file backing the room/VoIP-token registry. Point it at a mounted
    # volume (e.g. /data/registry.db on Railway) to survive redeploys; the default
    # cwd file is fine for local dev. ":memory:" for tests.
    registry_db_path: str = "registry.db"

    # --- Inbound calls (APNs VoIP push) ---
    # The .p8 auth key: a file path locally, or the base64 of its contents where a
    # file is awkward (e.g. a Railway variable). Key ID + Team ID come from the
    # Apple Developer portal. The engine rings BOTH APNs environments automatically
    # (it falls back on BadDeviceToken), so apns_use_sandbox below only selects which
    # host is tried first.
    apns_key_path: str | None = None
    apns_key_base64: str | None = None
    apns_key_id: str | None = None
    apns_team_id: str | None = None
    # Normally derived from the registered bundle_id + ".voip"; override only if
    # your topic differs from the app's bundle id.
    apns_topic: str | None = None
    # Which APNs host to try first (the other is the automatic fallback): false →
    # production first (App Store/TestFlight, the normal case); true → sandbox first
    # (set this only when iterating on dev-signed Xcode builds, to skip a round-trip).
    apns_use_sandbox: bool = False

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
