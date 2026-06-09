"""Bot entrypoint — one async ``bot()`` for the dev runner, plus a ``__main__``
that branches between two launch modes converging on ``run_bot``:

  * production: ``python -m bot.bot --transport … --agent … --token …``
    (the dispatcher spawns this per call). Builds the transport from argv.
  * local dev: ``python -m bot.bot`` (no dispatch args) → the Pipecat dev runner
    serves a prebuilt client at :7860/client. Pick the agent with CONDUIT_AGENT.

The bot never learns which path launched it — everything it needs is on its args.
"""

from __future__ import annotations

import argparse
import asyncio
import sys

from pipecat.runner.types import DailyRunnerArguments, RunnerArguments
from pipecat.runner.utils import create_transport

from app.config import settings
from bot.runtime import run_bot
from bot.transport_factory import DEV_TRANSPORT_PARAMS, build_transport


def _dev_transport_type(runner_args: RunnerArguments) -> str:
    if isinstance(runner_args, DailyRunnerArguments):
        return "daily"
    return "webrtc"


async def bot(runner_args: RunnerArguments) -> None:
    """Dev-runner entry. The runner calls this once per local session."""
    transport = await create_transport(runner_args, DEV_TRANSPORT_PARAMS)
    body = getattr(runner_args, "body", None) or {}
    agent_id = body.get("agent") or settings.conduit_agent
    await run_bot(
        transport,
        agent_id,
        _dev_transport_type(runner_args),
        handle_sigint=getattr(runner_args, "handle_sigint", True),
    )


def _is_dispatch_invocation(argv: list[str]) -> bool:
    # The dispatcher always passes --token; its absence means "run the dev runner".
    return "--token" in argv


async def _run_from_cli() -> None:
    parser = argparse.ArgumentParser(description="Conduit bot (dispatched subprocess)")
    parser.add_argument("--transport", required=True, choices=["daily", "livekit"])
    parser.add_argument("--agent", required=True)
    parser.add_argument("--token", required=True)
    parser.add_argument("--room-url")  # daily
    parser.add_argument("--url")  # livekit server url
    parser.add_argument("--room-name")  # livekit
    args = parser.parse_args()

    if args.transport == "daily":
        creds = {"room_url": args.room_url, "token": args.token}
    else:
        creds = {"url": args.url, "token": args.token, "room_name": args.room_name}

    transport = build_transport(args.transport, creds)
    await run_bot(transport, args.agent, args.transport, handle_sigint=True)


if __name__ == "__main__":
    if _is_dispatch_invocation(sys.argv[1:]):
        asyncio.run(_run_from_cli())
    else:
        from pipecat.runner.run import main

        main()
