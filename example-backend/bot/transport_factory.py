"""Build the transport the bot joins.

Two entry points:
- ``build_transport`` — production path: construct DailyTransport / LiveKitTransport
  directly from creds the dispatcher passed on argv.
- ``DEV_TRANSPORT_PARAMS`` — the param factories the dev runner's
  ``create_transport`` uses for local single-bot iteration (webrtc / daily).

The pipeline is identical across transports — this is the seam that proves the
client's "swap the transport" claim.
"""

from __future__ import annotations

from pipecat.transports.base_transport import BaseTransport, TransportParams

from app.config import settings


def build_transport(transport_type: str, creds: dict) -> BaseTransport:
    """Construct a transport from dispatcher-supplied creds.

    creds keys:
      daily   -> {"room_url", "token"}
      livekit -> {"url", "token", "room_name"}
    """
    if transport_type == "daily":
        from pipecat.transports.daily.transport import DailyParams, DailyTransport

        return DailyTransport(
            creds["room_url"],
            creds["token"],
            settings.bot_name,
            params=DailyParams(audio_in_enabled=True, audio_out_enabled=True),
        )

    if transport_type == "livekit":
        from pipecat.transports.livekit.transport import LiveKitParams, LiveKitTransport

        return LiveKitTransport(
            url=creds["url"],
            token=creds["token"],
            room_name=creds["room_name"],
            params=LiveKitParams(audio_in_enabled=True, audio_out_enabled=True),
        )

    raise ValueError(f"Unknown transport type: {transport_type!r}")


# Param factories for the dev runner (pipecat.runner.utils.create_transport).
# Lambdas defer construction until the transport is selected at runtime.
DEV_TRANSPORT_PARAMS = {
    "daily": lambda: _daily_dev_params(),
    "webrtc": lambda: TransportParams(audio_in_enabled=True, audio_out_enabled=True),
}


def _daily_dev_params():
    from pipecat.transports.daily.transport import DailyParams

    return DailyParams(audio_in_enabled=True, audio_out_enabled=True)
