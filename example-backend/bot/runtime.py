"""The launch-agnostic bot core.

``run_bot`` takes a built transport, an agent id, and the transport type, then:
builds the pipeline, greets when the user is on the line (``call-connected``, for
a client that sends it) or when the client is ready (any other), honors the
explicit end-call signal and the call-control signals (bot/call_control.py),
applies the grace-window teardown policy, and runs the worker. It does not know
or care whether a pairing call, a webhook, a ring, or a dev script launched it; a
ring only adds the ring deadline.
"""

from __future__ import annotations

import asyncio
import json
from collections.abc import AsyncIterator, Callable

from pipecat.frames.frames import ClientConnectedFrame
from pipecat.workers.runner import WorkerRunner

from app.config import settings
from app.obs import event, get_logger
from app.rings import CANCEL_ENDED, CANCEL_REFUSED, CONTROL_REPLY_PREFIX
from bot.call_control import CallControl
from bot.pipelines import live, loopback, tone
from bot.teardown import TeardownController

# Agent registry (bot side): id -> pipeline builder. The dispatcher keeps the
# richer AgentConfig (defaults, model config); both share these id strings.
_BUILDERS = {
    "loopback": loopback.build,
    "live": live.build,
    "tone": tone.build,
}

END_CALL = "end-call"


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


async def _client_signal(
    signal: str | None, controller: TeardownController, call: CallControl, log, via: str
) -> None:
    """Apply one client-message ``t`` from the app: end-call or a call-control signal."""
    if signal == END_CALL:
        # Explicit end signal disambiguates a real hangup from a dropped
        # connection (design §2.5). Reserves the grace window for genuine drops.
        event(log, "bot.end_call_signal", via=via)
        await controller.end_now("client-end-call")
    elif signal is not None and await call.handle(signal):
        event(log, "bot.call_signal", signal=signal, via=via)


def _livekit_client_signal(data) -> str | None:
    """The ``t`` of an RTVI client-message envelope in a raw LiveKit data packet."""
    try:
        msg = json.loads(data)
    except (ValueError, TypeError):
        return None
    if (
        isinstance(msg, dict)
        and msg.get("label") == "rtvi-ai"
        and msg.get("type") == "client-message"
        and isinstance(msg.get("data"), dict)
    ):
        return msg["data"].get("t")
    return None


def _wire_rtvi(rtvi, controller: TeardownController, call: CallControl, agent_id: str, log) -> None:
    @rtvi.event_handler("on_client_ready")
    async def _on_client_ready(rtvi):  # noqa: ANN001
        # set_bot_ready() is called automatically by the framework.
        event(log, "bot.client_ready", agent=agent_id)
        await call.client_ready()

    @rtvi.event_handler("on_client_message")
    async def _on_client_message(rtvi, message):  # noqa: ANN001
        await _client_signal(getattr(message, "type", None), controller, call, log, "rtvi")


def _wire_presence(
    transport, transport_type: str, controller: TeardownController, call: CallControl, log
) -> None:
    """Funnel transport-specific join/leave (and, where the RTVI input path can't
    carry them, client messages) events into the neutral controller.

    The events differ by transport (the seam), but the policy is identical.
    """
    if transport_type in ("daily",):

        @transport.event_handler("on_participant_joined")
        async def _on_join(transport, participant):  # noqa: ANN001
            controller.human_joined(_daily_pid(participant))
            await call.human_joined(_daily_pid(participant))

        @transport.event_handler("on_participant_left")
        async def _on_left(transport, participant, reason):  # noqa: ANN001
            controller.human_left(_daily_pid(participant))
            call.human_left(_daily_pid(participant))

    elif transport_type == "livekit":

        @transport.event_handler("on_participant_connected")
        async def _on_conn(transport, participant_id):  # noqa: ANN001
            controller.human_joined(participant_id)
            # The Conduit LiveKit adapter sends no RTVI client-ready (and it couldn't
            # reach RTVI anyway, see below), so the first join stands in for it.
            if await call.human_joined(participant_id):
                await call.client_ready()

        # A human already in the room when the bot connects (the phone can beat a
        # starting bot into the room) fires only this event: no
        # on_participant_connected and no ClientConnectedFrame. For a later join it
        # fires after on_participant_connected, whose handler has already counted
        # the join, so this one does nothing.
        @transport.event_handler("on_first_participant_joined")
        async def _on_first(transport, participant_id):  # noqa: ANN001
            controller.human_joined(participant_id)
            if await call.human_joined(participant_id):
                await transport.input().push_frame(ClientConnectedFrame())
                await call.client_ready()

        @transport.event_handler("on_participant_left")
        async def _on_left(transport, participant_id, reason):  # noqa: ANN001
            controller.human_left(participant_id)
            call.human_left(participant_id)

        # Pipecat's LiveKit input path re-wraps incoming data-channel messages as
        # OUTPUT frames, so client RTVI messages never reach the RTVI processor —
        # parse end-call and the call-control signals from the raw data event.
        @transport.event_handler("on_data_received")
        async def _on_data(transport, data, participant_id):  # noqa: ANN001
            signal = _livekit_client_signal(data)
            await _client_signal(signal, controller, call, log, "livekit-data")

    else:  # smallwebrtc / webrtc dev runner: client-level events are the signal
        @transport.event_handler("on_client_connected")
        async def _on_conn(transport, client):  # noqa: ANN001
            controller.human_joined(_client_id(client))
            await call.human_joined(_client_id(client))

        # End immediately instead of granting the grace window: the iOS client
        # has no in-place reconnect — its retry sends a NEW offer, which spawns a
        # new bot, so a grace timer on the dead peer connection only burns money
        # and races the replacement.
        @transport.event_handler("on_client_disconnected")
        async def _on_disc(transport, client):  # noqa: ANN001
            await controller.end_now("client-left")


def reply_on_stdout(ended: bool) -> None:
    """The ring bot's verdict on a cancel, read by the dispatcher (stdout is the
    reply channel of a control bot; logs go to stderr)."""
    verdict = CANCEL_ENDED if ended else CANCEL_REFUSED
    print(f"{CONTROL_REPLY_PREFIX}cancel {verdict}", flush=True)


async def run_bot(
    transport,
    agent_id: str,
    transport_type: str,
    *,
    handle_sigint: bool = True,
    handle_sigterm: bool = True,
    await_connected: bool = False,
    joins_before_answer: bool = False,
    ring_deadline_secs: float | None = None,
    control: AsyncIterator[str] | None = None,
    control_reply: Callable[[bool], None] | None = reply_on_stdout,
) -> None:
    """``await_connected`` / ``joins_before_answer`` / ``ring_deadline_secs``: see
    bot/call_control.py.
    ``control``: lines from the dispatcher (a ring bot's stdin); "answered" is the
    ring's answered receipt, "cancel" a withdrawn ring (answered with
    ``reply_on_stdout`` unless ``control_reply`` says otherwise)."""
    log = get_logger("bot")

    build_fn = _BUILDERS.get(agent_id)
    if build_fn is None:
        raise ValueError(f"Unknown agent_id: {agent_id!r} (have {sorted(_BUILDERS)})")

    bot_build = build_fn(transport)
    worker = bot_build.worker
    controller = TeardownController(
        worker,
        settings.human_absent_grace_secs,
        log,
        held_grace_secs=settings.held_grace_secs,
    )
    call = CallControl(
        teardown=controller,
        greet=bot_build.on_ready,
        gates=bot_build.gates,
        await_connected=await_connected,
        joins_before_answer=joins_before_answer,
        ring_deadline_secs=ring_deadline_secs,
        connected_grace_secs=settings.call_connected_grace_secs,
        log=log,
    )

    # worker.rtvi is a property that *raises* (not AttributeError) when RTVI is
    # disabled, so getattr's default wouldn't catch it — guard explicitly. The
    # shipped pipelines enable RTVI; this keeps a future no-RTVI pipeline from crashing.
    try:
        rtvi = worker.rtvi
    except Exception:
        rtvi = None
    if rtvi is not None:
        _wire_rtvi(rtvi, controller, call, agent_id, log)

    _wire_presence(transport, transport_type, controller, call, log)

    event(
        log,
        "bot.starting",
        agent=agent_id,
        transport=transport_type,
        await_connected=await_connected,
        joins_before_answer=joins_before_answer,
        ring_deadline=ring_deadline_secs,
    )
    call.start()
    control_task = (
        asyncio.create_task(_read_control(control, call, log, control_reply)) if control else None
    )
    # Subprocess bots take handle_sigterm so the dispatcher's /admin/disconnect
    # (SIGTERM) tears down gracefully. In-process bots (smallwebrtc) must pass
    # False for both — installing handlers there would clobber uvicorn's own.
    runner = WorkerRunner(handle_sigint=handle_sigint, handle_sigterm=handle_sigterm)
    try:
        await runner.add_workers(worker)
        await runner.run()
    finally:
        call.stop()
        if control_task is not None:
            control_task.cancel()
    event(log, "bot.finished", agent=agent_id, transport=transport_type)


async def _read_control(
    lines: AsyncIterator[str],
    call: CallControl,
    log,
    reply: Callable[[bool], None] | None = None,
) -> None:
    async for line in lines:
        if line == "answered":
            await call.receipt_answered()
        elif line == "cancel":
            await call.cancel(reply)
        else:
            event(log, "bot.control_ignored", line=line)
