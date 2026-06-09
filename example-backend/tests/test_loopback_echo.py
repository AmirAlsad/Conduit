"""Loopback must actually echo. A bare input() -> output() silently drops mic
audio because the output transport only emits OutputAudioRawFrame while the mic
yields InputAudioRawFrame. AudioEcho converts one to the other — regression-guard
that conversion so the pipe never goes silent again."""

from pipecat.frames.frames import InputAudioRawFrame, OutputAudioRawFrame
from pipecat.processors.frame_processor import FrameDirection

from bot.pipelines.loopback import AudioEcho


async def test_audio_echo_converts_input_audio_to_output_audio():
    echo = AudioEcho()
    captured = []

    async def fake_push(frame, direction=FrameDirection.DOWNSTREAM):
        captured.append(frame)

    echo.push_frame = fake_push  # capture what flows toward the output transport

    audio = b"\x10\x20" * 160
    await echo.process_frame(
        InputAudioRawFrame(audio=audio, sample_rate=16000, num_channels=1),
        FrameDirection.DOWNSTREAM,
    )

    outs = [f for f in captured if isinstance(f, OutputAudioRawFrame)]
    assert len(outs) == 1, "exactly one OutputAudioRawFrame should be emitted"
    assert outs[0].audio == audio  # same PCM, echoed back
    assert outs[0].sample_rate == 16000
    assert outs[0].num_channels == 1
