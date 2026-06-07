# Conduit Web Test Client

A standalone harness to talk to a Conduit bot from a laptop, built on the Pipecat
**Voice UI Kit** Console (Daily transport). It shows the RTVI speaking-state glow,
live transcripts, and an event log — the dev's verification harness before the
iOS app exists.

## Run

```bash
cd clients/web
npm install
npm run dev          # http://localhost:5173
```

1. Get a payload from the engine:
   ```bash
   curl -s -X POST http://localhost:8000/connect \
     -H "Authorization: Bearer $ENGINE_API_KEY" \
     -H "Content-Type: application/json" \
     -d '{"agent_id":"loopback","transport":"daily"}'
   ```
2. Paste the JSON into the page and click **Connect**.
3. Talk. With `loopback` you hear your own voice back; with `live` you get the
   greeting and a conversation.

## ⚠️ LiveKit caveat

There is no official Pipecat JS **LiveKit** client transport yet, so this Voice UI
Kit harness drives **Daily only**. To exercise a LiveKit payload, use
[meet.livekit.io](https://meet.livekit.io) or the LiveKit Agents Playground with
the `url` + `token` from the payload — or just use the iOS app.
