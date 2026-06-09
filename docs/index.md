# Conduit

**Bring-your-own-agent voice calling for iOS.** Conduit turns any voice agent you
already run into a hands-free phone call: it places a native call (CallKit, so it
rings, routes through Bluetooth and CarPlay, and lives on the lock screen) and
carries real-time audio over WebRTC. The agent — model, voice, persona, memory —
is entirely **yours**.

There is **no Conduit backend, no account, and no per-minute cost**. The app talks
only to the endpoint you give it; your credentials live in the device Keychain and
never leave your phone except to reach your own server.

```
 your voice           Conduit (iOS)                 your backend
 ─────────►  CallKit call ⇄ WebRTC transport  ⇄  your agent (STT·LLM·TTS)
              Bluetooth / CarPlay / lock screen     Daily or LiveKit room
```

## Connect your agent

Three ways in, depending on how much you want to read:

1. **[Overview](connect-your-agent.md)** — how connecting works: pairing vs.
   direct rooms, one endpoint per agent, what the app sends and expects.
2. **[Connection contract](CONNECTION_CONTRACT.md)** — the precise request and
   response shapes. Hand this to whoever runs your agent's backend.
3. **[Example backend quickstart](backend/quickstart.md)** — a working, self-hosted
   reference backend (FastAPI + Pipecat, Daily and LiveKit) you can deploy under
   your own keys and point the app at today.

Your server can also **call you**: see [Inbound calls](INBOUND_CALLS.md) for the
agent-initiated direction (VoIP push → real ringing call).

## The app

Conduit is open source and built from this repository:

```bash
git clone https://github.com/AmirAlsad/Conduit.git
cd Conduit
xcodegen generate          # the .xcodeproj is generated, not committed
open Conduit.xcodeproj     # build the Conduit scheme onto your device
```

A real two-way call needs a physical device — CallKit and microphone capture
don't run on the simulator.
