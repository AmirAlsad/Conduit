"""The `tone` test agent: a continuous tone from the first human join, no keys,
and nothing that waits for client-ready or call-answered."""

import array
import asyncio

from pipecat.frames.frames import (
    ClientConnectedFrame,
    InputAudioRawFrame,
    OutputAudioRawFrame,
    StartFrame,
)
from pipecat.processors.frame_processor import FrameDirection, FrameProcessor

from app.agents import get_agent
from bot.pipelines import tone


def _capture(src):
    out = []

    async def push(frame, direction=FrameDirection.DOWNSTREAM):
        out.append(frame)

    src.push_frame = push
    src.create_task = lambda coro, name=None: asyncio.create_task(coro)
    return out


def test_tone_period_is_one_clean_second():
    pcm = tone.tone_period(24000)
    samples = array.array("h")
    samples.frombytes(pcm)
    assert len(samples) == 24000
    assert samples[0] == 0
    assert max(samples) > 9000  # about -10 dBFS: clearly audible


async def test_tone_starts_on_the_human_join_and_drops_caller_audio():
    src = tone.ToneSource()
    out = _capture(src)
    await src.process_frame(StartFrame(audio_out_sample_rate=16000), FrameDirection.DOWNSTREAM)
    await src.process_frame(
        InputAudioRawFrame(audio=b"\x01\x00" * 160, sample_rate=16000, num_channels=1),
        FrameDirection.DOWNSTREAM,
    )
    await asyncio.sleep(0.05)
    assert not src.playing
    assert not any(isinstance(f, OutputAudioRawFrame) for f in out)

    await src.process_frame(ClientConnectedFrame(), FrameDirection.DOWNSTREAM)
    await asyncio.sleep(0.11)
    audio = [f for f in out if isinstance(f, OutputAudioRawFrame)]
    # Paced in real time: ~20 ms per chunk, so a handful in 110 ms, not hundreds.
    assert 3 <= len(audio) <= 8
    assert all(f.sample_rate == 16000 and len(f.audio) == 320 * 2 for f in audio)
    assert not any(isinstance(f, InputAudioRawFrame) for f in out)
    src._task.cancel()


def test_tone_agent_needs_no_keys_and_ignores_answer_and_ready():
    assert get_agent("tone").required_settings == ()

    class FakeTransport:
        def input(self):
            return FrameProcessor()

        def output(self):
            return FrameProcessor()

    build = tone.build(FakeTransport())
    assert build.on_ready is None  # client-ready does nothing
    assert build.gates == ()  # nothing for call-answered or hold to open or close
