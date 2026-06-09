# Bring your own agent

This guide moved to the published docs site so it can't drift from the rest of the
connection documentation:

**→ [Bring your own pipeline](https://amiralsad.github.io/Conduit/backend/bring-your-own-pipeline/)**
(source: [`docs/backend/bring-your-own-pipeline.md`](../../docs/backend/bring-your-own-pipeline.md))

The short version: you write one pipeline factory (`build(transport) -> BotBuild`),
register it in `bot/runtime.py` (`_BUILDERS`) and `app/agents.py` (`AGENTS`), and
`https://your-host/connect/myagent` becomes the pairing endpoint to paste into the
Conduit app. The engine supplies transport, dispatch, RTVI, teardown, and the
greet hook around your pipeline. Reference examples:
[`bot/pipelines/live.py`](../bot/pipelines/live.py) (copy this) and
[`bot/pipelines/loopback.py`](../bot/pipelines/loopback.py).
