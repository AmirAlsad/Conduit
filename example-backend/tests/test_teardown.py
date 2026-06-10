"""Grace-window teardown policy (design §2.5)."""

import asyncio
import json

from app.obs import get_logger
from bot.runtime import _wire_presence
from bot.teardown import TeardownController

_log = get_logger("test")


class FakeWorker:
    def __init__(self):
        self.cancelled = 0

    async def cancel(self):
        self.cancelled += 1


class FakeEventTransport:
    """Mimics pipecat's @transport.event_handler registration."""

    def __init__(self):
        self.handlers = {}

    def event_handler(self, name):
        def deco(fn):
            self.handlers[name] = fn
            return fn

        return deco


async def test_grace_expiry_tears_down():
    w = FakeWorker()
    c = TeardownController(w, grace_secs=0.05, log=_log)
    c.human_joined("a")
    c.human_left("a")
    await asyncio.sleep(0.15)
    assert w.cancelled == 1


async def test_rejoin_within_grace_resumes():
    w = FakeWorker()
    c = TeardownController(w, grace_secs=0.2, log=_log)
    c.human_joined("a")
    c.human_left("a")
    await asyncio.sleep(0.05)
    c.human_joined("a")  # reconnect before the window closes
    await asyncio.sleep(0.25)
    assert w.cancelled == 0  # conversation survives the drop


async def test_explicit_end_is_immediate():
    w = FakeWorker()
    c = TeardownController(w, grace_secs=100, log=_log)
    c.human_joined("a")
    await c.end_now("client-end-call")
    assert w.cancelled == 1


async def test_one_of_several_humans_leaving_does_not_tear_down():
    w = FakeWorker()
    c = TeardownController(w, grace_secs=0.05, log=_log)
    c.human_joined("a")
    c.human_joined("b")
    c.human_left("a")
    await asyncio.sleep(0.15)
    assert w.cancelled == 0  # b is still present, room not empty


# The LiveKit end-call signal rides the raw data channel (pipecat's LiveKit input
# path doesn't deliver client RTVI messages to the RTVI processor). These lock in
# the exact wire shape the Conduit app publishes on deliberate hangup.

END_CALL_WIRE = json.dumps(
    {"id": "ab12cd34", "label": "rtvi-ai", "type": "client-message", "data": {"t": "end-call"}}
).encode()


async def test_livekit_data_end_call_ends_immediately():
    w = FakeWorker()
    c = TeardownController(w, grace_secs=100, log=_log)
    t = FakeEventTransport()
    _wire_presence(t, "livekit", c, _log)
    c.human_joined("a")
    await t.handlers["on_data_received"](t, END_CALL_WIRE, "a")
    assert w.cancelled == 1


async def test_livekit_data_ignores_other_messages():
    w = FakeWorker()
    c = TeardownController(w, grace_secs=100, log=_log)
    t = FakeEventTransport()
    _wire_presence(t, "livekit", c, _log)
    c.human_joined("a")
    for payload in (
        b"not json",
        json.dumps({"label": "rtvi-ai", "type": "client-message", "data": {"t": "other"}}).encode(),
        json.dumps({"label": "other", "type": "client-message", "data": {"t": "end-call"}}).encode(),
        json.dumps(["rtvi-ai"]).encode(),
    ):
        await t.handlers["on_data_received"](t, payload, "a")
    assert w.cancelled == 0
