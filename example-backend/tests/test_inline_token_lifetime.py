"""An inline ring's credentials ride the push, and the app reuses them for every
connection attempt of the call, reconnects included (it asks the pairing
endpoint again only for pairing credentials). So the phone's token must stay
valid for the whole call on every transport, not the few minutes of a pairing
token, which the app replaces on each engine-level reconnect."""

import pytest
from fastapi.testclient import TestClient

from app.config import settings
from app.main import app

from test_connect_flow import FakeDaily, FakeDispatcher, FakeLiveKit
from test_inbound import AUTH, REGISTER_BODY, FakeApns
from test_webrtc_offer import FakeSmallWebRTC


class TtlDaily(FakeDaily):
    def __init__(self):
        self.ttls = {}  # owner -> ttl_secs

    async def mint_token(self, room_url, *, ttl_secs, owner):
        self.ttls[owner] = ttl_secs
        return await super().mint_token(room_url, ttl_secs=ttl_secs, owner=owner)


class TtlLiveKit(FakeLiveKit):
    def __init__(self):
        self.user_ttls = []

    def user_token(self, room_name, *, ttl_secs):
        self.user_ttls.append(ttl_secs)
        return super().user_token(room_name, ttl_secs=ttl_secs)


class TtlSmallWebRTC(FakeSmallWebRTC):
    def __init__(self):
        super().__init__()
        self.ttls = []

    def mint_token(self, agent_id, ttl_secs, *, await_connected=False):
        self.ttls.append(ttl_secs)
        return super().mint_token(agent_id, ttl_secs, await_connected=await_connected)


def _setup(c, transport):
    app.state.daily = TtlDaily()
    app.state.livekit = TtlLiveKit()
    app.state.smallwebrtc = TtlSmallWebRTC()
    app.state.dispatcher = FakeDispatcher()
    app.state.apns = FakeApns()
    body = {**REGISTER_BODY, "transport": transport}
    assert c.post("/inbound/register/loopback", json=body, headers=AUTH).status_code == 200


def _app_ttl(transport):
    if transport == "daily":
        return app.state.daily.ttls[False]
    if transport == "livekit":
        (ttl,) = app.state.livekit.user_ttls
        return ttl
    (ttl,) = app.state.smallwebrtc.ttls
    return ttl


@pytest.mark.parametrize("transport", ["daily", "livekit", "smallwebrtc"])
def test_an_inline_rings_phone_token_lasts_as_long_as_a_pairing_room(transport):
    with TestClient(app) as c:
        _setup(c, transport)
        r = c.post("/admin/ring/loopback", json={"inline": True}, headers=AUTH)
        assert r.status_code == 200, r.text
        assert _app_ttl(transport) == settings.pairing_room_exp_secs
        assert settings.pairing_room_exp_secs > settings.pairing_token_ttl_secs


@pytest.mark.parametrize("transport", ["daily", "livekit", "smallwebrtc"])
def test_a_pairing_token_stays_short_lived(transport):
    with TestClient(app) as c:
        _setup(c, transport)
        r = c.post("/connect/loopback", json={"transport": transport}, headers=AUTH)
        assert r.status_code == 200, r.text
        assert _app_ttl(transport) == settings.pairing_token_ttl_secs
