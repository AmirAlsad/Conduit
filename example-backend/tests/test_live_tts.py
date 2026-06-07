"""The `live` TTS stage is swappable via TTS_PROVIDER, reusing that provider's key."""

import pytest

from app.config import MissingSettingError, settings
from bot.pipelines import live


def test_tts_provider_selection(monkeypatch):
    # conftest sets deepgram/groq/cartesia keys, so each provider constructs offline.
    monkeypatch.setattr(settings, "tts_provider", "deepgram")
    assert type(live._build_tts()).__name__ == "DeepgramTTSService"
    monkeypatch.setattr(settings, "tts_provider", "groq")
    assert type(live._build_tts()).__name__ == "GroqTTSService"
    monkeypatch.setattr(settings, "tts_provider", "cartesia")
    assert type(live._build_tts()).__name__ == "CartesiaTTSService"


def test_unknown_tts_provider_raises(monkeypatch):
    monkeypatch.setattr(settings, "tts_provider", "nope")
    with pytest.raises(MissingSettingError):
        live._build_tts()
