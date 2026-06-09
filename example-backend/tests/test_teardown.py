"""Grace-window teardown policy (design §2.5)."""

import asyncio

from app.obs import get_logger
from bot.teardown import TeardownController

_log = get_logger("test")


class FakeWorker:
    def __init__(self):
        self.cancelled = 0

    async def cancel(self):
        self.cancelled += 1


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
