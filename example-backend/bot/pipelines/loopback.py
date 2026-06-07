"""`loopback` pipeline — echo the caller's audio back.

`transport.input() -> echo -> transport.output()`. No model, no keys, no external
deps, ~zero added latency (design §2.2). This isolates the audio path so a problem
here is the *pipe* (CallKit↔WebRTC activation, route switching, mute, the
speaker-not-earpiece default, raw quality), not the agent.

Note: a bare `input() -> output()` does NOT echo — the output transport only emits
`OutputAudioRawFrame`, while the mic yields `InputAudioRawFrame` (a sibling class).
`AudioEcho` converts one to the other so the bot actually speaks the caller's audio.

RTVI is still on (PipelineWorker default), but with no TTS the bot-speaking glow
would stay dark. Optionally insert a tiny energy-gate that synthesizes
bot-speaking state while echoing, so the client's glow can be exercised without
standing up the full model pipeline. Gated by ``LOOPBACK_BOT_SPEAKING`` (default
on); set it false for the truly pure pipe.
"""

from __future__ import annotations

import array
import math
import time

from pipecat.frames.frames import (
    BotStartedSpeakingFrame,
    BotStoppedSpeakingFrame,
    InputAudioRawFrame,
    OutputAudioRawFrame,
)
from pipecat.pipeline.pipeline import Pipeline
from pipecat.pipeline.worker import PipelineParams, PipelineWorker
from pipecat.processors.frame_processor import FrameDirection, FrameProcessor

from app.config import settings
from bot.buildresult import BotBuild


def _rms(pcm16: bytes) -> float:
    """Root-mean-square amplitude of int16 mono PCM."""
    if not pcm16 or len(pcm16) < 2:
        return 0.0
    samples = array.array("h")
    samples.frombytes(pcm16[: len(pcm16) // 2 * 2])
    if not samples:
        return 0.0
    return math.sqrt(sum(s * s for s in samples) / len(samples))


class SyntheticBotSpeaking(FrameProcessor):
    """Emit BotStarted/StoppedSpeaking frames from inbound audio energy.

    Self-contained (no VAD model, no keys): an RMS gate with hangover. The
    RTVIObserver picks the frames up and drives the client's speaking glow while
    loopback echoes — letting the glow be exercised on the bare pipe.
    """

    def __init__(self, *, threshold: float, hangover_secs: float = 0.4):
        super().__init__()
        self._threshold = threshold
        self._hangover = hangover_secs
        self._speaking = False
        self._last_loud = 0.0

    async def process_frame(self, frame, direction: FrameDirection):
        await super().process_frame(frame, direction)
        if isinstance(frame, InputAudioRawFrame):
            await self._gate(frame.audio)
        await self.push_frame(frame, direction)

    async def _gate(self, pcm16: bytes) -> None:
        now = time.monotonic()
        if _rms(pcm16) >= self._threshold:
            self._last_loud = now
            if not self._speaking:
                self._speaking = True
                await self.push_frame(BotStartedSpeakingFrame(), FrameDirection.DOWNSTREAM)
        elif self._speaking and (now - self._last_loud) >= self._hangover:
            self._speaking = False
            await self.push_frame(BotStoppedSpeakingFrame(), FrameDirection.DOWNSTREAM)


class AudioEcho(FrameProcessor):
    """Re-emit inbound mic audio as the bot's output audio.

    The output transport only writes `OutputAudioRawFrame`; the mic produces
    `InputAudioRawFrame`. Without this conversion the audio is silently dropped at
    the sink and the caller hears nothing. The output transport resamples to its
    own rate, so we just forward the same PCM with the source rate/channels.
    """

    async def process_frame(self, frame, direction: FrameDirection):
        await super().process_frame(frame, direction)
        if isinstance(frame, InputAudioRawFrame):
            await self.push_frame(
                OutputAudioRawFrame(
                    audio=frame.audio,
                    sample_rate=frame.sample_rate,
                    num_channels=frame.num_channels,
                ),
                FrameDirection.DOWNSTREAM,
            )
        else:
            await self.push_frame(frame, direction)


def build(transport) -> BotBuild:
    processors = [transport.input()]

    if settings.loopback_bot_speaking:
        processors.append(SyntheticBotSpeaking(threshold=settings.loopback_rms_threshold))

    processors.append(AudioEcho())  # the actual echo (input audio -> output audio)
    processors.append(transport.output())

    worker = PipelineWorker(
        Pipeline(processors),
        params=PipelineParams(enable_metrics=True),
        idle_timeout_secs=settings.pipeline_idle_timeout_secs,
    )
    return BotBuild(worker=worker, on_ready=None)
