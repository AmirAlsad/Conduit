"""A bot's room token reaches it through its environment, never its argv: argv is
readable by every user on the host (``ps``), and a Daily bot token is an owner
token for the room."""

import asyncio
import os
import sys

from app.dispatch import Dispatcher
from app.provisioning import dispatch_for_webhook
from app.registry import RoomRecord, SQLiteRegistry
from bot.bot import _is_dispatch_invocation

from test_connect_flow import FakeDaily, FakeDispatcher, FakeLiveKit
from test_dispatch import FakeProc


async def test_the_dispatcher_puts_bot_env_in_the_subprocess_environment(monkeypatch):
    seen = {}

    async def fake_exec(*args, **kwargs):
        seen["args"] = args
        seen["env"] = kwargs["env"]
        return FakeProc()

    monkeypatch.setattr(asyncio, "create_subprocess_exec", fake_exec)
    disp = Dispatcher(SQLiteRegistry(":memory:"))
    await disp.dispatch(
        room_key="r1", agent_id="loopback", transport="daily",
        bot_argv=["--token-env", "CONDUIT_BOT_TOKEN"], bot_env={"CONDUIT_BOT_TOKEN": "secret"},
    )
    assert seen["env"]["CONDUIT_BOT_TOKEN"] == "secret"
    assert "secret" not in seen["args"]
    # The rest of the environment (the settings the bot loads) is inherited.
    assert seen["env"]["ENGINE_API_KEY"] == os.environ["ENGINE_API_KEY"]
    assert "CONDUIT_BOT_TOKEN" not in os.environ


async def test_webhook_bots_get_their_token_through_the_environment():
    class State:
        daily = FakeDaily()
        livekit = FakeLiveKit()
        dispatcher = FakeDispatcher()

    for record in (
        RoomRecord(room_key="room-abc", agent_id="loopback", transport="daily", room_url="https://x.daily.co/room-abc"),
        RoomRecord(room_key="conduit-1", agent_id="loopback", transport="livekit", room_url=None),
    ):
        await dispatch_for_webhook(State, record)
    assert State.dispatcher.envs == [
        {"CONDUIT_BOT_TOKEN": "token-bot"}, {"CONDUIT_BOT_TOKEN": "lk-token-bot"}
    ]
    for _, _, _, argv in State.dispatcher.calls:
        assert "token-bot" not in argv and "lk-token-bot" not in argv


def test_a_token_env_argument_is_a_dispatch_invocation():
    assert _is_dispatch_invocation(["--transport", "daily", "--agent", "live", "--token-env", "X"])


async def test_the_cli_reads_the_token_from_the_named_variable(monkeypatch):
    import bot.bot as entry

    seen = {}

    async def fake_run_bot(transport, agent_id, transport_type, **kwargs):
        pass

    monkeypatch.setattr(entry, "build_transport", lambda kind, creds: seen.update(creds))
    monkeypatch.setattr(entry, "run_bot", fake_run_bot)
    monkeypatch.setenv("CONDUIT_BOT_TOKEN", "from-env")
    monkeypatch.setattr(sys, "argv", [
        "bot", "--transport", "daily", "--agent", "live", "--token-env", "CONDUIT_BOT_TOKEN",
        "--room-url", "https://x",
    ])
    await entry._run_from_cli()
    assert seen["token"] == "from-env"
