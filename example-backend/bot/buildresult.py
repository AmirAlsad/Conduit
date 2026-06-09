"""Neutral type returned by pipeline builders, kept here to avoid a
pipeline<->runtime import cycle."""

from __future__ import annotations

from collections.abc import Awaitable, Callable
from dataclasses import dataclass


@dataclass
class BotBuild:
    """What a pipeline module hands back to the runtime.

    - ``worker``: the configured PipelineWorker to run.
    - ``on_ready``: optional coroutine factory invoked when the RTVI client is
      ready (e.g. speak an opening line). ``None`` for pipelines that don't greet.
    """

    worker: object  # pipecat.pipeline.worker.PipelineWorker
    on_ready: Callable[[], Awaitable[None]] | None = None
