"""Registry behavior + agent/transport resolution."""

from app.agents import AGENTS, get_agent, resolve_transport
from app.registry import InMemoryRegistry


async def test_enable_and_get_room():
    reg = InMemoryRegistry()
    assert await reg.get_room("r1") is None
    await reg.enable_room("r1", "live", "daily", room_url="https://x.daily.co/r1")
    rec = await reg.get_room("r1")
    assert rec is not None
    assert (rec.agent_id, rec.transport, rec.room_url) == (
        "live",
        "daily",
        "https://x.daily.co/r1",
    )


async def test_active_bot_lifecycle():
    reg = InMemoryRegistry()
    assert await reg.active_bot("r1") is None
    await reg.set_active_bot("r1", 4242)
    assert await reg.active_bot("r1") == 4242
    await reg.clear_active_bot("r1")
    assert await reg.active_bot("r1") is None


def test_get_agent_known_and_unknown():
    assert get_agent("loopback").agent_id == "loopback"
    assert get_agent("live").agent_id == "live"
    try:
        get_agent("nope")
        assert False, "expected KeyError"
    except KeyError:
        pass


def test_resolve_transport_precedence():
    live = AGENTS["live"]
    # requested wins
    assert resolve_transport(live, "livekit") == "livekit"
    # else agent default
    assert resolve_transport(AGENTS["loopback"], None) == "daily"
