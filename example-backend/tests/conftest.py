"""Test environment. Set config env BEFORE any app import so the cached Settings
load with deterministic, network-free values."""

import base64
import os

os.environ.setdefault("ENGINE_API_KEY", "test-engine-key")
# Throwaway registry per TestClient lifespan; never write a db file into cwd.
os.environ.setdefault("REGISTRY_DB_PATH", ":memory:")
os.environ.setdefault("DAILY_API_KEY", "test-daily-key")
os.environ.setdefault(
    "DAILY_WEBHOOK_SECRET", base64.b64encode(b"daily-webhook-secret").decode()
)
os.environ.setdefault("LIVEKIT_API_KEY", "devkey")
os.environ.setdefault("LIVEKIT_API_SECRET", "devsecretdevsecretdevsecretdevsecret")
os.environ.setdefault("LIVEKIT_URL", "wss://example.livekit.cloud")
# Model keys present so the `live` agent passes the dispatcher's pre-spawn key check.
os.environ.setdefault("DEEPGRAM_API_KEY", "test-deepgram-key")
os.environ.setdefault("GROQ_API_KEY", "test-groq-key")
os.environ.setdefault("CARTESIA_API_KEY", "test-cartesia-key")
os.environ.setdefault("BOT_NAME", "Conduit Bot")
os.environ.setdefault("HUMAN_ABSENT_GRACE_SECS", "60")
# Force APNs UNCONFIGURED (overriding any developer .env with a real key), so the
# real ApnsSender 503s instead of sending live pushes to Apple from the test suite.
os.environ["APNS_KEY_PATH"] = ""
os.environ["APNS_KEY_BASE64"] = ""
os.environ["APNS_KEY_ID"] = ""
os.environ["APNS_TEAM_ID"] = ""
os.environ["APNS_TOPIC"] = ""
