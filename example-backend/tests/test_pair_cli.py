"""scripts/pair.py — the conduit:// link builder. The URL shape is a contract
with the app's DeepLinkParser (ConduitTests/DeepLink): both sides test the
same parameters and encoding."""

import sys
from pathlib import Path
from urllib.parse import parse_qsl, urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))

from pair import build_link  # noqa: E402


def _params(link: str) -> dict[str, str]:
    return dict(parse_qsl(urlsplit(link).query))


def test_link_shape_and_param_order():
    link = build_link(
        base_url="https://host.example",
        agent_id="live",
        transport="livekit",
        name="Live Agent",
        key="sk-123",
        inbound=True,
    )
    assert link.startswith("conduit://add-agent?v=1&")
    params = _params(link)
    assert params == {
        "v": "1",
        "name": "Live Agent",
        "transport": "livekit",
        "pair": "https://host.example/connect/live",
        "key": "sk-123",
        "inbound": "https://host.example/inbound/register/live",
    }


def test_url_values_are_percent_encoded():
    link = build_link(
        base_url="https://host.example",
        agent_id="live",
        transport="daily",
        name="My Agent",
        key=None,
        inbound=False,
    )
    # Raw separators never appear inside values on the wire.
    assert "name=My%20Agent" in link
    assert "pair=https%3A%2F%2Fhost.example%2Fconnect%2Flive" in link


def test_no_key_omits_the_param():
    link = build_link(
        base_url="https://host.example",
        agent_id="loopback",
        transport="daily",
        name="Loopback",
        key=None,
        inbound=False,
    )
    params = _params(link)
    assert "key" not in params
    assert "inbound" not in params


def test_trailing_slash_base_url_is_normalized():
    link = build_link(
        base_url="https://host.example/",
        agent_id="live",
        transport="daily",
        name="Live",
        key=None,
        inbound=True,
    )
    params = _params(link)
    assert params["pair"] == "https://host.example/connect/live"
    assert params["inbound"] == "https://host.example/inbound/register/live"
