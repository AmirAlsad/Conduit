"""Neutral type returned by pipeline builders, kept here to avoid a
pipeline<->runtime import cycle."""

from __future__ import annotations

from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field


@dataclass
class BotBuild:
    """What a pipeline module hands back to the runtime.

    - ``worker``: the configured PipelineWorker to run.
    - ``on_ready``: optional coroutine factory invoked when the client is ready
      (e.g. speak an opening line). ``None`` for pipelines that don't greet.
    - ``gates``: the pipeline's audio gates (bot.call_control.AudioGate), closed
      while a ring awaits its answer and while the call is on hold. Empty for a
      pipeline that ignores both (the tone test agent).
    """

    worker: object  # pipecat.pipeline.worker.PipelineWorker
    on_ready: Callable[[], Awaitable[None]] | None = None
    gates: tuple = field(default_factory=tuple)
