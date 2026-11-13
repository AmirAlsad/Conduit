"""The dispatcher refuses to start without a real ENGINE_API_KEY: it is the bearer
on every billable route (and the admin key), so an empty or example value would
leave the engine open to anyone who read the docs."""

import pytest
from fastapi.testclient import TestClient

from app.config import InsecureSettingError, MissingSettingError, settings
from app.main import app


@pytest.mark.parametrize("key", [None, "", "   "])
def test_the_engine_refuses_to_start_without_a_key(monkeypatch, key):
    monkeypatch.setattr(settings, "engine_api_key", key)
    with pytest.raises(MissingSettingError):
        with TestClient(app):
            pass


@pytest.mark.parametrize(
    "key", ["changeme-long-random-string", "changeme", "CHANGEME", " changeme-long-random-string "]
)
def test_the_engine_refuses_to_start_with_a_placeholder_key(monkeypatch, key):
    monkeypatch.setattr(settings, "engine_api_key", key)
    with pytest.raises(InsecureSettingError):
        with TestClient(app):
            pass


def test_the_engine_starts_with_a_real_key(monkeypatch):
    monkeypatch.setattr(settings, "engine_api_key", "b3f1c0d2e4a5968778695a4b3c2d1e0f")
    with TestClient(app) as c:
        assert c.get("/health").status_code == 200


def test_the_example_env_ships_no_key():
    from pathlib import Path

    example = Path(__file__).resolve().parent.parent / ".env.example"
    lines = [l for l in example.read_text().splitlines() if l.startswith("ENGINE_API_KEY=")]
    assert lines == ["ENGINE_API_KEY="]
