# Bring your own agent

This engine's job is to make **your** voice agent reachable as a Conduit call. You
supply a pipeline; the engine supplies everything around it — credentials,
dispatch, the transport, RTVI plumbing, reconnection-safe teardown, the greet
hook. This guide is the integration: the factory you write, where you register it,
and the contract it must honor.

The reference agents [`bot/pipelines/loopback.py`](../bot/pipelines/loopback.py)
and [`bot/pipelines/live.py`](../bot/pipelines/live.py) are working examples — copy
`live` as your starting point.

---

## The one thing you write: a pipeline factory

```python
# bot/pipelines/myagent.py
from pipecat.pipeline.pipeline import Pipeline
from pipecat.pipeline.worker import PipelineParams, PipelineWorker
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

`build()` takes the transport and returns a [`BotBuild`](../bot/buildresult.py):

| field | meaning |
|---|---|
| `worker` | the configured `PipelineWorker` to run |
| `on_ready` | optional async callable, invoked when the RTVI client is ready (greet here); `None` to stay silent until the caller speaks |

That's the whole surface. You don't construct the transport, parse a token, manage
the subprocess, wire teardown, or handle the end-call signal — the entrypoint
([`bot/runtime.py:run_bot`](../bot/runtime.py)) does all of that around your worker.

---

## Register it (two lines)

```python
# bot/runtime.py — map the id to your factory
_BUILDERS = {
    "loopback": loopback.build,
    "live": live.build,
    "myagent": myagent.build,      # ← add
}
```

```python
# app/agents.py — declare dispatch-time defaults + required keys
AGENTS["myagent"] = AgentConfig(
    "myagent",
    default_transport="daily",                 # used when /connect omits transport
    description="…",
    required_settings=("my_provider_api_key",), # validated BEFORE a bot is spawned
)
```

`required_settings` names must be fields on the `Settings` object — add any custom
key to [`app/config.py`](../app/config.py) (e.g. `my_provider_api_key: str | None =
None`). The dispatcher checks them on `/connect` / `/credentials` and returns a
clean **503** if one is missing, instead of minting creds for a bot that crashes on
launch (which would leave the caller connected to silence).

Then dispatch it:

```bash
curl -s -X POST http://localhost:8000/connect \
  -H "Authorization: Bearer $ENGINE_API_KEY" -H "Content-Type: application/json" \
  -d '{"agent_id":"myagent","transport":"daily"}'
```

---

## The contract your agent must satisfy

If you build on the provided entrypoint (the recipe above), you get all three for
free. They're listed because a from-scratch agent **must** honor them, and because
breaking one fails in ways that are easy to misdiagnose.

### 1. Transport-agnostic pipeline
You're handed a ready `transport`; build from `transport.input()` /
`transport.output()`. The identical pipeline must run on Daily and LiveKit — that's
what lets the client swap transports and attribute any difference to the
transport/client seam, not your agent. Don't hardcode a transport or its params.

### 2. RTVI speaking-state — the glow contract
The app's listening/speaking **glow is driven entirely by RTVI speaking-state
events** (`bot-started-speaking` / `bot-stopped-speaking`, plus user-side events).
`PipelineWorker` enables RTVI by default and its observer emits these automatically
as your TTS speaks — so a normal Pipecat pipeline satisfies this for free. **If you
disable RTVI, or bridge in a non-Pipecat agent that never emits these, the glow
stays dark** even though audio works. This is the single most-missed requirement.

(The `loopback` agent has no TTS, so it *synthesizes* the bot-speaking signal from
inbound audio energy — see `SyntheticBotSpeaking` — purely so the glow can be
exercised on the bare pipe. You won't need that with a real TTS stage.)

### 3. Reconnection-safe teardown
The iOS client drops media in tunnels/dead-zones and **reconnects with backoff**
while CallKit still shows the call up. The common agent pattern —
`on_participant_left → task.cancel()` — exits the instant the human's connection
blips, so the client reconnects into an empty room and the call is dead. Conduit's
contract:

- **Don't exit on human-left.** Start a `HUMAN_ABSENT_GRACE_SECS` timer; tear down
  only if no human rejoins. While you stay, the room is non-empty and a reconnecting
  caller resumes mid-conversation (context intact).
- **End immediately only on an explicit hangup** — the client sends RTVI
  `{"type":"end-call"}`, or the app calls `POST /admin/disconnect`. Without it, a
  real hangup just waits out the grace window (harmless, but billed).

[`bot/runtime.py:run_bot`](../bot/runtime.py) +
[`bot/teardown.py`](../bot/teardown.py) implement this for every registered agent —
you get it by using the entrypoint. If you write your own entrypoint, you must
reproduce it. `HUMAN_ABSENT_GRACE_SECS` is a **shared constant with the client
team**: ≥ the client's total reconnect-with-backoff budget, and no longer.

### Greeting (optional but recommended)
Return an `on_ready` from `build()` to speak the moment the session activates —
immediate downlink audio confirms the call connected. It fires on RTVI
`client-ready`, so it works on both transports and for the iOS client.

---

## "I already have a Pipecat bot"

Then you're ~done. Your existing pipeline already has `transport.input()`/`output()`
endpoints and a `PipelineWorker` — move the pipeline construction into a
`build(transport)` that returns `BotBuild(worker=...)`, register it, and delete your
own transport-creation/teardown code (the entrypoint owns that now). Keep your
services (STT/LLM/TTS, processors, context) exactly as they are.

## "My agent isn't Pipecat"

The clean path is to express it as a Pipecat pipeline — wrap your model calls as a
Pipecat service/`FrameProcessor` so RTVI speaking-state and teardown come for free.
If you must run an external agent, you bridge audio at the transport seam
(`transport.input()` frames → your agent → `OutputAudioRawFrame` back to
`transport.output()`) and then **you own the RTVI and teardown contracts yourself** —
emit `BotStartedSpeakingFrame`/`BotStoppedSpeakingFrame` around your speech and
honor the grace window. This is more work; prefer the Pipecat pipeline.

---

## Test your agent

```bash
# 1. In isolation, no dispatcher — talk to it in the browser:
CONDUIT_AGENT=myagent uv run python -m bot.bot        # http://localhost:7860/client

# 2. Through the dispatcher (the real path the app uses):
uv run uvicorn app.main:app --reload
curl -s -X POST http://localhost:8000/connect \
  -H "Authorization: Bearer $ENGINE_API_KEY" -H "Content-Type: application/json" \
  -d '{"agent_id":"myagent","transport":"daily"}'
# → paste the JSON into clients/web (npm run dev) and join.
```

Watch the dispatcher logs for `dispatch.accepted` → `bot.starting` → `Joined …`,
then `teardown.first_human` when you join. If the glow stays dark, check contract #2.

## Reference files

- [`bot/pipelines/live.py`](../bot/pipelines/live.py) — full reference agent (STT→LLM→TTS, RTVI, greet).
- [`bot/pipelines/loopback.py`](../bot/pipelines/loopback.py) — minimal; the pipe diagnostic.
- [`bot/runtime.py`](../bot/runtime.py) — the entrypoint that wires RTVI/teardown/greet around your worker.
- [`bot/buildresult.py`](../bot/buildresult.py) — the `BotBuild` contract.
- [`app/agents.py`](../app/agents.py) — the agent registry (defaults + required keys).
