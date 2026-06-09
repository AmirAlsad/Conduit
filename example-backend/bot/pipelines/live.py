"""`live` pipeline — the realistic end-to-end agent and documentation centerpiece.

à la carte ``input -> STT -> context -> LLM -> TTS -> output`` with RTVI on
(PipelineWorker default). Reference stack: Deepgram STT · Groq LLM · Cartesia TTS
— each a one-line swap (design §2.3). Greets on RTVI client-ready so there is
immediate downlink audio the moment the session activates. Barge-in is on by
default via VAD.
"""

from __future__ import annotations

from pipecat.audio.vad.silero import SileroVADAnalyzer
from pipecat.audio.vad.vad_analyzer import VADParams
from pipecat.frames.frames import LLMRunFrame
from pipecat.pipeline.pipeline import Pipeline
from pipecat.pipeline.worker import PipelineParams, PipelineWorker
from pipecat.processors.aggregators.llm_context import LLMContext
from pipecat.processors.aggregators.llm_response_universal import (
    LLMContextAggregatorPair,
    LLMUserAggregatorParams,
)
from pipecat.services.deepgram.stt import DeepgramSTTService
from pipecat.services.groq.llm import GroqLLMService

from app.config import MissingSettingError, settings
from bot.buildresult import BotBuild

# Which setting each TTS provider needs (mirrored in app/agents.py for pre-validation).
TTS_KEY = {
    "cartesia": "cartesia_api_key",
    "deepgram": "deepgram_api_key",
    "groq": "groq_api_key",
}

# Spoken-first thinking-partner persona. No formatting that can't be read aloud;
# tolerate silence rather than snap-respond.
PERSONA = (
    "You are a calm, attentive thinking partner in a live voice conversation. "
    "Your replies are spoken aloud, so never use emojis, markdown, bullet points, "
    "or anything that can't be read naturally. Keep replies brief and "
    "conversational. The person may pause to think — that's fine; don't rush to "
    "fill silence. Help them reason out loud."
)


def _build_tts():
    """TTS is the one-line-swappable stage (design §2.3), here as a TTS_PROVIDER knob.
    Each provider reuses that provider's existing key."""
    provider = settings.tts_provider.lower()
    if provider == "cartesia":
        from pipecat.services.cartesia.tts import CartesiaTTSService

        settings.require("cartesia_api_key")
        return CartesiaTTSService(
            api_key=settings.cartesia_api_key,
            settings=CartesiaTTSService.Settings(voice=settings.cartesia_voice_id),
        )
    if provider == "deepgram":
        from pipecat.services.deepgram.tts import DeepgramTTSService

        settings.require("deepgram_api_key")
        return DeepgramTTSService(api_key=settings.deepgram_api_key)  # Aura default voice
    if provider == "groq":
        from pipecat.services.groq.tts import GroqTTSService

        settings.require("groq_api_key")
        return GroqTTSService(api_key=settings.groq_api_key)  # PlayAI default voice
    raise MissingSettingError(f"Unknown TTS_PROVIDER: {settings.tts_provider!r}")


def build(transport) -> BotBuild:
    # Validate STT + LLM keys here; the TTS provider validates its own key.
    settings.require("deepgram_api_key", "groq_api_key")

    stt = DeepgramSTTService(api_key=settings.deepgram_api_key)

    llm = GroqLLMService(
        api_key=settings.groq_api_key,
        settings=GroqLLMService.Settings(
            model=settings.groq_model,
            system_instruction=PERSONA,
        ),
    )

    tts = _build_tts()

    context = LLMContext()
    user_aggregator, assistant_aggregator = LLMContextAggregatorPair(
        context,
        user_params=LLMUserAggregatorParams(
            # Turn-end detection is Pipecat's default stop strategy — Smart Turn v3
            # (LocalSmartTurnAnalyzerV3), applied automatically by the aggregator (you
            # don't wire it explicitly; you can see it load at startup). VAD here only
            # provides the trailing-silence signal Smart Turn consumes. VAD_STOP_SECS
            # is the endpointing knob (design §2.2): Smart Turn was trained at 0.2;
            # raising it buys a thinking-partner more silence tolerance, at some latency.
            vad_analyzer=SileroVADAnalyzer(params=VADParams(stop_secs=settings.vad_stop_secs)),
        ),
    )

    pipeline = Pipeline(
        [
            transport.input(),
            stt,
            user_aggregator,
            llm,
            tts,
            transport.output(),
            assistant_aggregator,
        ]
    )

    worker = PipelineWorker(
        pipeline,
        params=PipelineParams(enable_metrics=True, enable_usage_metrics=True),
        idle_timeout_secs=settings.pipeline_idle_timeout_secs,
    )

    async def on_ready() -> None:
        # Greet on connect: immediate downlink audio confirms the session activated
        # (Layer-1 connect-and-downlink check) and naturally opens the call.
        context.add_message(
            {"role": "developer", "content": "Briefly greet the user and invite them to talk."}
        )
        await worker.queue_frames([LLMRunFrame()])

    return BotBuild(worker=worker, on_ready=on_ready)
