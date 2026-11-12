"""SQLite registry: VoIP token storage + the persistence guarantees the volume
story rests on (rooms/tokens survive a reopen; active-bot pids deliberately don't)."""

import sqlite3

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


async def test_voip_roundtrip_with_display_name_and_handle():
    reg = SQLiteRegistry(":memory:")
    named = VoipRegistration(
        **{**_reg().__dict__, "display_name": "Ada", "handle": "ada@conduit.example"}
    )
    await reg.register_voip(named)
    stored = await reg.get_voip("live")
    assert stored == named
    assert (stored.display_name, stored.handle) == ("Ada", "ada@conduit.example")


async def test_voip_roundtrip_with_push_features():
    reg = SQLiteRegistry(":memory:")
    featured = VoipRegistration(
        **{**_reg().__dict__, "push_features": ("cancel", "ring_timeout", "teleport")}
    )
    await reg.register_voip(featured)
    assert await reg.get_voip("live") == featured
    # A later registration without features replaces them with none.
    await reg.register_voip(_reg())
    assert (await reg.get_voip("live")).push_features == ()


async def test_opens_old_six_column_voip_table_and_migrates(tmp_path):
    path = str(tmp_path / "old.db")
    old = sqlite3.connect(path)
    old.execute(
        """CREATE TABLE voip_tokens (
            backend_agent_id TEXT PRIMARY KEY,
            app_agent_id     TEXT NOT NULL,
            voip_token       TEXT NOT NULL,
            platform         TEXT NOT NULL,
            bundle_id        TEXT NOT NULL,
            updated_at       TEXT NOT NULL
        )"""
    )
    old.execute(
        "INSERT INTO voip_tokens VALUES (?, ?, ?, ?, ?, ?)",
        ("live", "11111111-1111-1111-1111-111111111111", "aabbcc", "ios",
         "com.example.Conduit", "2026-01-01T00:00:00+00:00"),
    )
    old.commit()
    old.close()

    reg = SQLiteRegistry(path)
    columns = {row[1] for row in reg._conn.execute("PRAGMA table_info(voip_tokens)")}
    assert {"display_name", "handle", "push_features"} <= columns
    legacy = await reg.get_voip("live")
    assert legacy == _reg()
    assert legacy.display_name is None and legacy.handle is None
    assert legacy.push_features == ()

    await reg.register_voip(
        VoipRegistration(
            **{
                **_reg().__dict__,
                "display_name": "Ada",
                "handle": "ada@conduit.example",
                "push_features": ("cancel",),
            }
        )
    )
    updated = await reg.get_voip("live")
    assert updated is not None
    assert (updated.display_name, updated.handle) == ("Ada", "ada@conduit.example")
    assert updated.push_features == ("cancel",)
    reg.close()

    # Reopening an already-migrated database must not try to add the columns again.
    reopened = SQLiteRegistry(path)
    assert (await reopened.get_voip("live")).push_features == ("cancel",)
    reopened.close()


async def test_migrates_a_table_that_already_has_names_but_not_features(tmp_path):
    # A database from the build that added display_name/handle but predates
    # push_features: its rows read back with no features.
    path = str(tmp_path / "named.db")
    old = sqlite3.connect(path)
    old.execute(
        """CREATE TABLE voip_tokens (
            backend_agent_id TEXT PRIMARY KEY,
            app_agent_id     TEXT NOT NULL,
            voip_token       TEXT NOT NULL,
            platform         TEXT NOT NULL,
            bundle_id        TEXT NOT NULL,
            updated_at       TEXT NOT NULL,
            display_name     TEXT,
            handle           TEXT
        )"""
    )
    old.execute(
        "INSERT INTO voip_tokens VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        ("live", "11111111-1111-1111-1111-111111111111", "aabbcc", "ios",
         "com.example.Conduit", "2026-06-01T00:00:00+00:00", "Ada", None),
    )
    old.commit()
    old.close()

    reg = SQLiteRegistry(path)
    stored = await reg.get_voip("live")
    assert stored.display_name == "Ada"
    assert stored.push_features == ()
    reg.close()


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
