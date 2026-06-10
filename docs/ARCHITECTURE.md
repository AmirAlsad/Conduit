# Architecture

> Status: built through **M6**, plus follow-ons. `Core/Models/` and `Core/Services/`
> are populated (protocol seams + fakes, SwiftData models, `AppEnvironment`,
> `CallSessionCoordinator`, reconnection, spoken state); all `Features/` modules and
> `Shared/` components are built; the **real** implementations are in —
> CallKit (`SystemCallProvider`, M3), both transports (`PipecatDailyTransport` M2,
> `LiveKitTransport` M6), and Keychain (`KeychainService`). Adding an agent to
> Contacts is permission-free (system Add-Contact sheet). Since M6: Recents
> swipe-to-delete, an audio-interruption seam (`AudioInterruptionObserving`), and
> agent-initiated inbound calls (VoIP push, `Core/Services/Push/`; see
> [INBOUND_CALLS](./INBOUND_CALLS.md)). The LiveKit call path is device-verified
> (pairing connect, two-way audio, native route button, reconnection — against the
> deployed reference engine, June 2026), and so is the **inbound path** (cold ring,
> answer, decline, inline creds, Focus-filtered → missed + local notification,
> busy report-and-end, redeploy survival — June 2026, LiveKit agent).
> See [CORE_SYSTEMS](./CORE_SYSTEMS.md).

## Overview

Conduit is a **thin audio pipe**: a native iOS app that turns a voice agent you
already run into a hands-free phone call. The app neither hosts nor knows the
agent's models — it places the call, routes the audio (including to the car over
Bluetooth/CarPlay), and shows call status. There is **no backend of ours**: the
user brings their own connection (Daily / LiveKit credentials they mint
themselves), so the app has no accounts, no token service, and no per-minute cost.

## The Three-Layer Model

The whole system is three conceptual layers. The app owns only the first two; the
third is the user's.

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
│      Transports are SWAPPABLE: Daily and LiveKit in this      │
│      build, SmallWebRTC later. Sits behind a protocol so the  │
│      logic layer can test against fakes.                       │
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
owns the audio session** — the app reports the call and lets the system activate
the session at the right moment. The one screen the app actually builds is the
in-app foreground in-call screen (the WhatsApp/Zoom pattern); the system owns the
locked-screen UI and cannot be replicated.

### (2) The transport layer — WebRTC (Pipecat iOS client)

Carries the live audio. Transports are interchangeable behind one client: **Daily
and LiveKit** in this build, **SmallWebRTC** as a later self-host transport.
Because model APIs ride inside the agent, supporting the orchestration transports
transitively covers every model and voice. This layer is meant to live behind a
protocol boundary so the call state machine, connection parsing, and transport
selection can unit-test against fakes (voice plan "Layer 1").

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
- **Interruptions.** Duck under transient system audio (nav prompts, alerts);
  yield entirely to a real incoming phone call.

## Folder Structure

```
Conduit/
├── App/            # Entry point + tab shell (ConduitApp, RootTabView)
├── Core/           # Shared, app-agnostic infrastructure
│   ├── Models/     # Pure value types + SwiftData @Models (Agent, CallLogEntry,
│   │               #   CallState, TransportKind, ReconnectionPolicy, …)
│   ├── Services/   # AppEnvironment (composition root) + the protocol seams:
│   │               #   Call/, CallKit/, Transport/, Keychain/, Contacts/,
│   │               #   Persistence/, Audio/, Push/, Pairing/  (each: protocol
│   │               #   + fake [+ real])
│   └── Utilities/  # Log (os.log), AccessibilityID base namespace, helpers
├── Features/       # Self-contained feature modules (Recents, Contacts,
│                   #   Settings, AgentDetail, AddEditAgent, InCall)
├── Shared/         # Reusable UI components, navigation
└── Resources/      # Assets, audio, data files
```

Within a feature: `Views/`, `ViewModels/`, optional `Models/`, `Services/`,
`Coordinators/`. Naming and the per-feature `AccessibilityID+<Feature>.swift`
convention are in [CONVENTIONS](./CONVENTIONS.md).

> **Coordinator placement.** `CallSessionCoordinator` lives in
> `Core/Services/Call/`, not under `Features/InCall/`. It is an app-wide service
> owned by `AppEnvironment` and consumed by multiple features (Recents redial,
> Contacts/AgentDetail call, the InCall projection), so placing it inside one
> feature would invert the dependency.

## App Surface (planned, from the plan)

Modeled on the iOS Phone app — three tabs plus two detail/modal surfaces:

- **Recents** (home) — the call log; redial-the-last-one behavior; cold-start
  empty state funnels to "add your first agent."
- **Contacts** — the list of agents, each treated as a contact (quick-call button).
- **Settings** — sparse: About + the global always-listening vs. push-to-talk toggle.
- **Agent Detail** — a contact-card view of one agent with a prominent Call
  button, plus "Add to Contacts" (the permission-free system Add-Contact sheet).
- **Add / Edit Agent** (sheet) — the bring-your-own configuration surface
  (name, description, avatar, connection, test-connection).

## Testing Posture (summary)

Three layers (full detail in [CORE_SYSTEMS](./CORE_SYSTEMS.md) and the CI workflow):

- **Layer 1 — logic, simulator, automated.** State machine, connection parsing,
  transport selection, error handling against fakes. Most bugs live here. Runs in
  CI. The `CallSessionCoordinator` + `ReconnectionPolicy` suites
  (`ConduitTests/Call/`) are the current Layer-1 coverage.
- **Layer 2 — integration, tethered device, scripted.** Genuine live CallKit +
  WebRTC calls. **Device-only — NOT run on CI simulator runners.**
- **Layer 3 — audio/routing, manual.** AirPods stand in for the car; validates
  route-switching and two-way audio that automation structurally can't reach.

## Out of Scope / Fast-Follows

The CarPlay dashboard app and its entitlement; QR / pairing-endpoint onboarding;
SmallWebRTC as a transport; reliable lock-screen "Hey Siri, call my agent"
dialing; a Favorites tab; cross-drive persistent memory (lives in the agent).
Each is a known next step, not a gap — sequenced (with rationale) in
[ROADMAP](./ROADMAP.md).
