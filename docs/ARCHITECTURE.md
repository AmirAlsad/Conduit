# Architecture

> Status: built through **M6**, plus follow-ons. The call engine (state machine,
> CallKit, PushKit, reconnection, the Daily and LiveKit adapters) is the
> `ConduitCallEngine` Swift package; the app holds everything agent-shaped —
> `Core/Models/` and `Core/Services/` (SwiftData models, `AppEnvironment`, the
> `AgentCalls/` glue, Keychain, pairing, contacts, Siri), all `Features/` modules
> and `Shared/` components, and the SmallWebRTC adapter. Adding an agent to
> Contacts is permission-free (system Add-Contact sheet). Recents has
> swipe-to-delete, and agents can ring the user (VoIP push; see
> [INBOUND_CALLS](./INBOUND_CALLS.md)). The app consumes engine 0.2.x — pre-connect
> while ringing, ring timeouts and cancel pushes, call-control signals to the agent,
> engine-driven sound cues, a join deadline. The latest device session (2026-11-12,
> iPhone 17, iOS 27.0, Daily, LiveKit and SmallWebRTC) and what it did not cover
> (among them Focus-filtered rings, which iOS 27.0 did not filter, and the SiriKit
> contact path) are recorded in [DEVICE_VERIFICATION](./DEVICE_VERIFICATION.md). The
> engine's call hold is experimental and the app leaves it off: a phone call ends
> the call ([ROADMAP](./ROADMAP.md) has the follow-up).
> See [CORE_SYSTEMS](./CORE_SYSTEMS.md).

## Overview

Conduit is a **thin audio pipe**: a native iOS app that turns a voice agent you
already run into a hands-free phone call. The app neither hosts nor knows the
agent's models — it places the call, routes the audio (including to the car over
Bluetooth/CarPlay), and shows call status. There is **no backend of ours**: the
user brings their own connection (Daily or LiveKit credentials they mint
themselves, or a SmallWebRTC server they run), so the app has no accounts, no token
service, and no per-minute cost.

## The Three-Layer Model

The whole system is three conceptual layers. The app owns only the first two —
implemented by the `ConduitCallEngine` package plus the app's own SmallWebRTC
adapter; the third is the user's.

```
┌─────────────────────────────────────────────────────────────┐
│  (1) Call layer — CallKit                                     │
│      Presents the agent session as a NATIVE call: system     │
│      call UI, lock screen, Dynamic Island, Bluetooth/CarPlay │
│      routing, mute/end. OWNS the audio session — reports the  │
│      call and hands activation to the system.                 │
└───────────────────────────┬─────────────────────────────────┘
                            │  ← the key seam: CallKit activates
                            │     the audio session; WebRTC media
                            │     attaches on activation, never
                            │     grabs the mic on its own.
┌───────────────────────────┴─────────────────────────────────┐
│  (2) Transport layer — WebRTC via the Pipecat iOS client     │
│      Carries real-time audio to/from the agent. Turn          │
│      detection + interruption handled by the framework.       │
│      Transports are SWAPPABLE: Daily, LiveKit, and            │
│      SmallWebRTC (self-hosted P2P). Sits behind a protocol    │
│      so the logic layer can test against fakes.                │
└───────────────────────────┬─────────────────────────────────┘
                            │  ← WebRTC transport (user's room/token)
┌───────────────────────────┴─────────────────────────────────┐
│  (3) The agent — THE USER'S, not ours                        │
│      STT, the LLM, TTS, voice selection, memory/persona.      │
│      The app neither knows nor cares which models are behind  │
│      it. Model APIs (OpenAI Realtime, Gemini Live, …) ride    │
│      INSIDE the agent over the same transport.                │
└─────────────────────────────────────────────────────────────┘
```

### (1) The call layer — CallKit

Presents the agent session as a system call so it behaves like the native Phone
app: lock-screen controls, Dynamic Island pill, status-bar indicator, the
CarPlay/Bluetooth call display, and a real entry in the system Recents. **CallKit
owns the audio session** — the engine reports the call and lets the system
activate the session at the right moment. The one screen the app actually builds is the
in-app foreground in-call screen (the WhatsApp/Zoom pattern); the system owns the
locked-screen UI and cannot be replicated.

### (2) The transport layer — WebRTC (Pipecat iOS client)

Carries the live audio. Transports are interchangeable behind one client: **Daily
and LiveKit** over their clouds, and **SmallWebRTC** peer-to-peer with the user's
own server (LAN / self-hosted — the zero-cloud option).
Because model APIs ride inside the agent, supporting the orchestration transports
transitively covers every model and voice. The layer sits behind the
`CallTransport` protocol so the call state machine, connection parsing, and
transport selection can unit-test against fakes (voice plan "Layer 1").
The protocol also lets a transport state what it can do: whether it can join a
room while the phone still rings (`canConnectWhileRinging` — LiveKit and Daily yes;
SmallWebRTC no), and whether a call-control
signal (`call-connected`; `call-held` and `call-resumed` only with the engine's
experimental hold, which the app leaves off) reached the agent
(`send(_:)`'s `CallSignalDelivery`). The engine adapts to what each one reports.

### (3) The agent — the user's

Everything that makes an agent *its* agent — STT, the LLM, TTS, the voice, the
persona, the memory — runs on the user's own infrastructure. Conduit places no
constraints on it beyond "speaks a supported WebRTC transport." Agent design and
iteration are explicitly **out of scope** for this app.

## The Key Seam: CallKit ↔ WebRTC Audio Session

The one genuinely fiddly boundary, and where most of the real work lives. The
system call lifecycle must own **activation** of the audio session; the WebRTC
media attaches to it **on activation**, rather than seizing the microphone
independently. Getting this handshake right is the crux; the rest is wiring.
Related hazards to design for (detailed in [CORE_SYSTEMS](./CORE_SYSTEMS.md)):

- **Reconnection.** A dropped WebRTC connection leaves CallKit thinking the call
  is still up. Reconnect with backoff; speak state in a built-in synthesis voice
  (distinct from the agent's) since the agent is exactly what's unreachable.
- **Interruptions and phone calls.** Duck under transient system audio (nav
  prompts, alerts); pause the mic for a full takeover (Siri). A phone call the user
  accepts or places ends the call: calls are not holdable. Holding instead (the mic
  closed, the transport detached, the agent told with `call-held` /
  `call-resumed`) is an experimental engine opt-in the app leaves off, because on a
  device the audio did not come back after a real phone call
  ([ROADMAP](./ROADMAP.md)).

## Folder Structure

The call engine is the **`ConduitCallEngine`** Swift package, consumed by
version from `github.com/AmirAlsad/ConduitCallEngine` (set in `project.yml`,
`minorVersion: "0.2.0"`, 0.2.x only). It holds layers (1) and (2)
and their fakes; the app holds the agents, the UI, and the glue that joins them.

```
Conduit/
├── App/            # Entry point + tab shell (ConduitApp, AppDelegate, RootTabView)
├── Core/           # Shared, app-agnostic infrastructure
│   ├── Models/     # Agent, CallLogEntry (SwiftData @Models), TransportKind,
│   │               #   AgentColor, KeychainTokenRef, SpokenPhrase, …
│   ├── Services/   # AppEnvironment (composition root) + the app's services:
│   │               #   AgentCalls/ (engine glue), Transport/ (SmallWebRTC
│   │               #   adapter), Keychain/, Contacts/, Persistence/, Audio/
│   │               #   (spoken state), Push/ (token registration, missed-call
│   │               #   notification), Pairing/, Siri/, DeepLink/
│   └── Utilities/  # Log (os.log), AccessibilityID base namespace, helpers
├── Features/       # Self-contained feature modules (Recents, Contacts,
│                   #   Settings, AgentDetail, AddEditAgent, InCall)
├── Shared/         # Reusable UI components, navigation
├── Debug/          # DEBUG-only: call trace, Cue Lab, device spikes
└── Resources/      # Assets, audio, data files

ConduitCallEngine (package)      # consumed by version
├── Sources/ConduitCallEngine/         # core: Call/ (CallEngine, CallTarget,
│                                      #   CallEngineDelegate), CallKit/, Push/,
│                                      #   Transport/ (CallTransport + event
│                                      #   types), Models/, Utilities/
├── Sources/ConduitCallEngineDaily/    # PipecatDailyTransport
├── Sources/ConduitCallEngineLiveKit/  # LiveKitTransport + audio router/gate
├── Sources/ConduitCallEngineTesting/  # FakeTransport, SimulatedCallSystem,
│                                      #   CallEngine.simulated(...)
└── Tests/                             # engine, Daily and LiveKit tests
```

Within a feature: `Views/`, `ViewModels/`, optional `Models/`, `Services/`,
`Coordinators/`. Naming and the per-feature `AccessibilityID+<Feature>.swift`
convention are in [CONVENTIONS](./CONVENTIONS.md).

> **Engine placement.** `CallEngine` is an app-wide service: `AppEnvironment` owns
> one instance and several features consume it (Recents redial, Contacts/AgentDetail
> call, the InCall projection), so it sits outside any feature — in the package.
> It knows calls, not agents. The host reaches it through its public surface only
> (`CallTarget`, `CallEngineDelegate`, `CallEngineConfiguration`), and
> `Core/Services/AgentCalls/` is the one place that turns an `Agent` into a
> `CallTarget` and reacts to the engine's callbacks.

## App Surface

Modeled on the iOS Phone app — three tabs plus two detail/modal surfaces:

- **Recents** (home) — the call log; redial-the-last-one behavior; cold-start
  empty state funnels to "add your first agent."
- **Contacts** — the list of agents, each treated as a contact (quick-call button).
- **Settings** — the global always-listening vs. push-to-talk toggle, and About (the
  version, the privacy note, and a link to connecting your agent).
- **Agent Detail** — a contact-card view of one agent with a prominent Call
  button, plus "Add to Contacts" (the permission-free system Add-Contact sheet).
- **Add / Edit Agent** (sheet) — the bring-your-own configuration surface
  (name, description, avatar, connection, test-connection).

## Testing Posture (summary)

Three layers (full detail in [CORE_SYSTEMS](./CORE_SYSTEMS.md) and the CI workflow):

- **Layer 1 — logic, simulator, automated.** State machine, connection parsing,
  transport selection, error handling against fakes. Most bugs live here. Runs in
  CI. The engine's suites (`CallEngine`, push handling, reconnection, credential
  resolution, the Daily and LiveKit adapters' logic) live in the package's
  `Tests/`; the host's (`AgentCallHost`, `Agent+CallTarget`, pairing, Siri
  matching, view-model logic) in `ConduitTests/`.
- **Layer 2 — integration, tethered device, scripted.** Genuine live CallKit +
  WebRTC calls. **Device-only — NOT run on CI simulator runners.**
- **Layer 3 — audio/routing, manual.** AirPods stand in for the car; validates
  route-switching and two-way audio that automation structurally can't reach.

## Out of Scope / Fast-Follows

The CarPlay dashboard app and its entitlement; reliable lock-screen "Hey Siri,
call my agent" dialing; a Favorites tab; cross-drive persistent memory (lives in
the agent). (QR onboarding shipped in M8; SmallWebRTC shipped in M9.)
Each is a known next step, not a gap — sequenced (with rationale) in
[ROADMAP](./ROADMAP.md).
