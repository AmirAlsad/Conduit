"""`tone` pipeline — a test agent for pre-connect checks on a device.

Plays a continuous 440 Hz tone from the moment a human joins the room, and
ignores client-ready, ``call-answered`` and hold. Ring a phone with
``preconnect: "media"`` and this agent: anything the phone lets out while it is
still ringing is audible. No model, no keys. The caller's audio is dropped.
"""

from __future__ import annotations

import array
import asyncio
import math

from pipecat.frames.frames import (
    ClientConnectedFrame,
    InputAudioRawFrame,
    OutputAudioRawFrame,
    StartFrame,
)
from pipecat.pipeline.pipeline import Pipeline
from pipecat.pipeline.worker import PipelineParams, PipelineWorker
from pipecat.processors.frame_processor import FrameDirection, FrameProcessor

from app.config import settings
from bot.buildresult import BotBuild

FREQUENCY_HZ = 440
# About -10 dBFS: loud enough to hear through an earpiece, not painful on a speaker.
AMPLITUDE = 0.3
CHUNK_SECS = 0.02


def tone_period(sample_rate: int) -> bytes:
    """One second of int16 mono sine: a whole number of cycles, so it loops cleanly."""
    peak = int(AMPLITUDE * 32767)
    samples = array.array(
        "h",
        (
            int(peak * math.sin(2 * math.pi * FREQUENCY_HZ * i / sample_rate))
            for i in range(sample_rate)
        ),
    )
    return samples.tobytes()


class ToneSource(FrameProcessor):
    """Starts a real-time tone on the first ClientConnectedFrame (both the Daily
    and the LiveKit input transport push one when a participant joins)."""

    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self._sample_rate = 24000
        self._task: asyncio.Task | None = None

    @property
    def playing(self) -> bool:
        return self._task is not None

    async def process_frame(self, frame, direction: FrameDirection):
        await super().process_frame(frame, direction)
        if isinstance(frame, StartFrame):
            self._sample_rate = frame.audio_out_sample_rate
        elif isinstance(frame, ClientConnectedFrame) and self._task is None:
            self._task = self.create_task(self._play(), name="tone")
        if isinstance(frame, InputAudioRawFrame):
            return
        await self.push_frame(frame, direction)

    async def cleanup(self):
        await super().cleanup()
        if self._task is not None:
            await self.cancel_task(self._task)
            self._task = None

    async def _play(self) -> None:
        rate = self._sample_rate
        period = tone_period(rate)
        chunk_bytes = int(rate * CHUNK_SECS) * 2
        loop = asyncio.get_running_loop()
        start = loop.time()
        offset = 0
        sent = 0
        while True:
            end = offset + chunk_bytes
            if end <= len(period):
                chunk = period[offset:end]
            else:
                chunk = period[offset:] + period[: end - len(period)]
            offset = end % len(period)
            await self.push_frame(
                OutputAudioRawFrame(audio=chunk, sample_rate=rate, num_channels=1)
            )
            sent += 1
            # Paced against the start time, so the output queue never grows.
            await asyncio.sleep(max(0.0, start + sent * CHUNK_SECS - loop.time()))


def build(transport) -> BotBuild:
    worker = PipelineWorker(
        Pipeline([transport.input(), ToneSource(), transport.output()]),
        params=PipelineParams(enable_metrics=True),
        idle_timeout_secs=settings.pipeline_idle_timeout_secs,
    )
    return BotBuild(worker=worker, on_ready=None)
