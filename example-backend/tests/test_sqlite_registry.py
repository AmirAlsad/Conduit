"""SQLite registry: VoIP token storage + the persistence guarantees the volume
story rests on (rooms/tokens survive a reopen; active-bot pids deliberately don't)."""

from app.registry import SQLiteRegistry, VoipRegistration


def _reg(agent="live", token="aabbcc", app_uuid="11111111-1111-1111-1111-111111111111"):
    return VoipRegistration(
        backend_agent_id=agent,
        app_agent_id=app_uuid,
        voip_token=token,
        platform="ios",
        bundle_id="com.example.Conduit",
    )


async def test_voip_register_get_delete_roundtrip():
    reg = SQLiteRegistry(":memory:")
    assert await reg.get_voip("live") is None
    await reg.register_voip(_reg())
    stored = await reg.get_voip("live")
    assert stored == _reg()
    await reg.delete_voip("live")
    assert await reg.get_voip("live") is None


async def test_latest_registration_wins():
    reg = SQLiteRegistry(":memory:")
    await reg.register_voip(_reg(token="old-token"))
    await reg.register_voip(_reg(token="new-token"))
    stored = await reg.get_voip("live")
    assert stored is not None and stored.voip_token == "new-token"


async def test_rooms_and_tokens_survive_reopen_but_active_bots_do_not(tmp_path):
    path = str(tmp_path / "registry.db")
    reg = SQLiteRegistry(path)
    await reg.enable_room("r1", "live", "daily", room_url="https://x.daily.co/r1")
    await reg.register_voip(_reg())
    await reg.set_active_bot("r1", 4242)
    reg.close()

    reopened = SQLiteRegistry(path)
    room = await reopened.get_room("r1")
    assert room is not None and room.agent_id == "live"
    assert await reopened.get_voip("live") == _reg()
    # Pids are process-local: a restarted dispatcher has no live bots, and a
    # persisted SPAWNING sentinel would block the room forever.
    assert await reopened.active_bot("r1") is None
    reopened.close()
