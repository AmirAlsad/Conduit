"""The launch-agnostic bot core.

``run_bot`` takes a built transport, an agent id, and the transport type, then:
builds the pipeline, greets on RTVI client-ready, honors an explicit end-call
signal, applies the grace-window teardown policy, and runs the worker. It does
not know or care whether a pairing call, a webhook, or a dev script launched it.
"""

from __future__ import annotations

import json

from pipecat.workers.runner import WorkerRunner

from app.config import settings
from app.obs import event, get_logger
from bot.pipelines import live, loopback
from bot.teardown import TeardownController

# Agent registry (bot side): id -> pipeline builder. The dispatcher keeps the
# richer AgentConfig (defaults, model config); both share these id strings.
_BUILDERS = {
    "loopback": loopback.build,
    "live": live.build,
}


def _daily_pid(participant: dict) -> str:
    return (
        participant.get("id")
        or participant.get("session_id")
        or participant.get("info", {}).get("userId")
        or str(id(participant))
    )


def _client_id(client) -> str:
    for attr in ("id", "client_id", "participant_id"):
        val = getattr(client, attr, None)
        if val:
            return str(val)
    if isinstance(client, dict):
        return str(client.get("id") or client.get("session_id") or id(client))
    return str(id(client))


def _wire_presence(transport, transport_type: str, controller: TeardownController, log) -> None:
    """Funnel transport-specific join/leave (and, where the RTVI input path can't
    carry it, end-call) events into the neutral controller.

    The events differ by transport (the seam), but the policy is identical.
    """
    if transport_type in ("daily",):

        @transport.event_handler("on_participant_joined")
        async def _on_join(transport, participant):  # noqa: ANN001
            controller.human_joined(_daily_pid(participant))

        @transport.event_handler("on_participant_left")
        async def _on_left(transport, participant, reason):  # noqa: ANN001
            controller.human_left(_daily_pid(participant))

    elif transport_type == "livekit":

        @transport.event_handler("on_participant_connected")
        async def _on_conn(transport, participant_id):  # noqa: ANN001
            controller.human_joined(participant_id)

        @transport.event_handler("on_participant_left")
        async def _on_left(transport, participant_id, reason):  # noqa: ANN001
            controller.human_left(participant_id)

        # Pipecat's LiveKit input path re-wraps incoming data-channel messages as
        # OUTPUT frames, so client RTVI messages never reach the RTVI processor —
        # parse the explicit end-call signal from the raw data event instead.
        @transport.event_handler("on_data_received")
        async def _on_data(transport, data, participant_id):  # noqa: ANN001
            try:
                msg = json.loads(data)
            except (ValueError, TypeError):
                return
            if (
                isinstance(msg, dict)
                and msg.get("label") == "rtvi-ai"
                and msg.get("type") == "client-message"
                and (msg.get("data") or {}).get("t") == "end-call"
            ):
                event(log, "bot.end_call_signal", via="livekit-data")
                await controller.end_now("client-end-call")

    else:  # smallwebrtc / webrtc dev runner: client-level events are the signal
        @transport.event_handler("on_client_connected")
        async def _on_conn(transport, client):  # noqa: ANN001
            controller.human_joined(_client_id(client))

        # End immediately instead of granting the grace window: the iOS client
        # has no in-place reconnect — its retry sends a NEW offer, which spawns a
        # new bot, so a grace timer on the dead peer connection only burns money
        # and races the replacement.
        @transport.event_handler("on_client_disconnected")
        async def _on_disc(transport, client):  # noqa: ANN001
            await controller.end_now("client-left")


async def run_bot(
    transport,
    agent_id: str,
    transport_type: str,
    *,
    handle_sigint: bool = True,
    handle_sigterm: bool = True,
) -> None:
    log = get_logger("bot")

    build_fn = _BUILDERS.get(agent_id)
    if build_fn is None:
        raise ValueError(f"Unknown agent_id: {agent_id!r} (have {sorted(_BUILDERS)})")

    bot_build = build_fn(transport)
    worker = bot_build.worker
    controller = TeardownController(worker, settings.human_absent_grace_secs, log)

    # worker.rtvi is a property that *raises* (not AttributeError) when RTVI is
    # disabled, so getattr's default wouldn't catch it — guard explicitly. Both
    # shipped pipelines enable RTVI; this keeps a future no-RTVI pipeline from crashing.
    try:
        rtvi = worker.rtvi
    except Exception:
        rtvi = None
    if rtvi is not None:

        @rtvi.event_handler("on_client_ready")
        async def _on_client_ready(rtvi):  # noqa: ANN001
            # set_bot_ready() is called automatically by the framework.
            event(log, "bot.client_ready", agent=agent_id)
            if bot_build.on_ready is not None:
                await bot_build.on_ready()

        @rtvi.event_handler("on_client_message")
        async def _on_client_message(rtvi, message):  # noqa: ANN001
            # Explicit end signal disambiguates a real hangup from a dropped
            # connection (design §2.5). Reserves the grace window for genuine drops.
            if getattr(message, "type", None) == "end-call":
                event(log, "bot.end_call_signal")
                await controller.end_now("client-end-call")

    _wire_presence(transport, transport_type, controller, log)

    event(log, "bot.starting", agent=agent_id, transport=transport_type)
    # Subprocess bots take handle_sigterm so the dispatcher's /admin/disconnect
    # (SIGTERM) tears down gracefully. In-process bots (smallwebrtc) must pass
    # False for both — installing handlers there would clobber uvicorn's own.
    runner = WorkerRunner(handle_sigint=handle_sigint, handle_sigterm=handle_sigterm)
    await runner.add_workers(worker)
    await runner.run()
    event(log, "bot.finished", agent=agent_id, transport=transport_type)
