"""Test environment. Set config env BEFORE any app import so the cached Settings
load with deterministic, network-free values."""

import base64
import os

os.environ.setdefault("ENGINE_API_KEY", "test-engine-key")
os.environ.setdefault("DAILY_API_KEY", "test-daily-key")
os.environ.setdefault(
    "DAILY_WEBHOOK_SECRET", base64.b64encode(b"daily-webhook-secret").decode()
)
os.environ.setdefault("LIVEKIT_API_KEY", "devkey")
os.environ.setdefault("LIVEKIT_API_SECRET", "devsecretdevsecretdevsecretdevsecret")
os.environ.setdefault("LIVEKIT_URL", "wss://example.livekit.cloud")
os.environ.setdefault("BOT_NAME", "Conduit Bot")
os.environ.setdefault("HUMAN_ABSENT_GRACE_SECS", "60")
