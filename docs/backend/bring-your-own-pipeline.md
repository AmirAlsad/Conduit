# Bring your own pipeline

The engine's job is to make **your** agent reachable as a Conduit call. You supply
a pipeline; the engine supplies everything around it — credentials, dispatch, the
transport, RTVI plumbing, reconnection-safe teardown, the greet hook. The
reference agents
[`bot/pipelines/loopback.py`](https://github.com/AmirAlsad/Conduit/blob/main/example-backend/bot/pipelines/loopback.py)
and
[`bot/pipelines/live.py`](https://github.com/AmirAlsad/Conduit/blob/main/example-backend/bot/pipelines/live.py)
are working examples — copy `live` as your starting point.

## The one thing you write: a pipeline factory

```python
# bot/pipelines/myagent.py
from pipecat.pipeline.pipeline import Pipeline
from pipecat.pipeline.worker import PipelineWorker
from bot.buildresult import BotBuild

def build(transport) -> BotBuild:
    # `transport` is already built (Daily or LiveKit) and handed to you. Use its
    # input()/output(); the SAME pipeline runs on either transport.
    pipeline = Pipeline([
        transport.input(),
        # …your processors / services…
        transport.output(),
    ])
    worker = PipelineWorker(pipeline)   # RTVI on by default (the glow contract)

    async def on_ready():               # optional: speak an opening line
        await worker.queue_frames([...])

    return BotBuild(worker=worker, on_ready=on_ready)
```

You don't construct the transport, parse a token, manage the subprocess, wire
teardown, or handle the end-call signal — the entrypoint (`bot/runtime.py:run_bot`)
does all of that around your worker.

## Register it (two lines)

```python
# bot/runtime.py — map the id to your factory
_BUILDERS = {"loopback": loopback.build, "live": live.build, "myagent": myagent.build}

# app/agents.py — dispatch-time defaults + required keys
AGENTS["myagent"] = AgentConfig(
    "myagent",
    default_transport="daily",
    description="…",
    required_settings=("my_provider_api_key",),  # validated BEFORE a bot is spawned
)
```

`required_settings` names must be fields on the `Settings` object in
`app/config.py`. The dispatcher checks them on every credential request and
returns a clean **503** if one is missing — instead of minting credentials for a
bot that crashes on launch and leaves the caller in a silent room.

Then it's callable like any built-in agent:

```bash
curl -s -X POST http://localhost:8000/connect/myagent \
  -H "Authorization: Bearer $ENGINE_API_KEY" -H "Content-Type: application/json" \
  -d '{"transport":"daily"}'
```

…and `https://your-host/connect/myagent` is the pairing endpoint to paste into
the Conduit app.

## The contract your agent must satisfy

Building on the provided entrypoint gives you all three for free. They matter
because breaking one fails in ways that are easy to misdiagnose:

1. **Transport-agnostic pipeline.** You're handed a ready `transport`; build from
   `transport.input()` / `transport.output()`. The identical pipeline must run on
   Daily and LiveKit. Don't hardcode a transport.
2. **RTVI speaking-state — the glow contract.** The app's listening/speaking glow
   is driven *entirely* by RTVI speaking-state events. `PipelineWorker` emits them
   automatically (RTVI is on by default) as your TTS speaks. **If you disable RTVI
   or bridge in a non-Pipecat agent that never emits them, the glow stays dark**
   even though audio works — the single most-missed requirement.
3. **Reconnection-safe teardown.** The iOS client drops media in tunnels and
   dead-zones and reconnects with backoff while CallKit still shows the call up.
   Don't exit when the human leaves — stay for a grace window
   (`HUMAN_ABSENT_GRACE_SECS`) so a reconnecting caller resumes mid-conversation,
   and end immediately only on an explicit hangup (RTVI `{"type":"end-call"}` or
   `POST /admin/disconnect`). `bot/runtime.py` + `bot/teardown.py` implement this
   for every registered agent.

A **greeting** (`on_ready`) is optional but recommended — immediate downlink audio
confirms the call connected.

## Already have a Pipecat bot?

Then you're nearly done: move your pipeline construction into a
`build(transport)` returning `BotBuild(worker=...)`, register it, and delete your
own transport-creation/teardown code. Your services (STT/LLM/TTS, processors,
context) stay exactly as they are.

**Not Pipecat?** The clean path is to wrap your model calls as a Pipecat
service/`FrameProcessor` so RTVI and teardown come for free. Bridging an external
agent at the raw-audio seam is possible, but then you own the RTVI and teardown
contracts yourself.

## Test it

```bash
# In isolation, no dispatcher — talk to it in the browser:
CONDUIT_AGENT=myagent uv run python -m bot.bot      # http://localhost:7860/client

# Through the dispatcher (the path the app uses):
uv run uvicorn app.main:app --reload
curl -s -X POST http://localhost:8000/connect/myagent \
  -H "Authorization: Bearer $ENGINE_API_KEY" -H "Content-Type: application/json" \
  -d '{"transport":"daily"}'
```

Watch the dispatcher logs for `dispatch.accepted` → `bot.starting` → `Joined …`.
If audio works but the app's glow stays dark, revisit contract #2.
