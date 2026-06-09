# Conduit Documentation

Centralized, AI-optimized documentation for **Conduit** — a bring-your-own-agent
voice calling app for iOS. You bring the agent; the app supplies the ears, the
mouth, and the car. It places a native-feeling call (CallKit) to a voice agent
you already run, carrying audio over WebRTC via the Pipecat iOS client. No
backend of ours, no accounts, no per-minute cost.

## Quick Navigation

| Document | Purpose |
|----------|---------|
| [ROADMAP](./ROADMAP.md) | Where Conduit goes next and why in that order — the verification-debt-first sequence (M7+) toward calling and being called by your own agent. |
| [ARCHITECTURE](./ARCHITECTURE.md) | The three-layer model (CallKit / WebRTC transport / the user's agent), folder structure, the key seams. |
| [CONVENTIONS](./CONVENTIONS.md) | Code style, naming, AccessibilityID convention, the per-developer build override model, logging standards. |
| [CORE_SYSTEMS](./CORE_SYSTEMS.md) | Shared infrastructure: the protocol seams + fakes, SwiftData models, AppEnvironment, the call state machine, reconnection/spoken state, the audio-session/CallKit wiring, audio-interruption handling, and the inbound-call path. |
| [CONNECTION_CONTRACT](./CONNECTION_CONTRACT.md) | How a user's agent backend connects to Conduit — the pairing-endpoint request/response shapes and the direct-room fallback. Hand this to whoever runs the agent. |
| [INBOUND_CALLS](./INBOUND_CALLS.md) | How a user's own server rings the user through Conduit (agent-initiated VoIP-push calls) — token registration + push payload contract. The inbound companion to the connection contract. |
| [AGENT_WORKFLOW](./AGENT_WORKFLOW.md) | Operational playbook for agents driving the app: build nuances, UI verification, flow testing, the reporting contract, and the shell fallback. |

Feature docs (`docs/features/<Feature>.md`) are added as features land — see the
plan's three-tab structure (Recents, Contacts, Settings) plus Agent Detail and
the in-call screen.

## Load Order for Agents

These docs are written to be fed to an agent as context. Load them in order so
each builds on the last instead of grepping blindly:

1. **`ARCHITECTURE.md`** first — understand the three-layer model and the
   CallKit↔WebRTC seam before touching anything.
2. **`CONVENTIONS.md`** next — house style, naming, the AccessibilityID and build
   override rules you must follow.
3. **`CORE_SYSTEMS.md`** for shared infrastructure (call/transport/audio/reconnect).
4. The **relevant feature doc** under `docs/features/` last, once features exist.

## Project Facts (orientation)

- **Build:** XcodeGen. `project.yml` is the source of truth; the `.xcodeproj` is
  generated and gitignored, so you must run `xcodegen generate` after any
  `project.yml` change or fresh clone. Scheme: `Conduit`.
- **Structure:** `Conduit/{App, Core, Features, Shared, Resources}`.
- **Testing pin:** the simulator is pinned to iPhone 16 / iOS 18.6 (the iOS 26
  sim has a broken accessibility subsystem). Core CallKit + WebRTC live calls are
  device-only; CI covers logic/unit + UI smoke only.
- **Decisions:** no backend, no Firebase, no analytics. Logging goes through the
  `Log` utility (os.log) in `Core/Utilities`.

## Key Technologies

- **SwiftUI** — declarative UI (`@Observable`, async/await).
- **CallKit** — presents the agent session as a native call and owns the audio session.
- **WebRTC via the Pipecat iOS client** — real-time transport to the agent
  (Daily / LiveKit transports, swappable).
- **The agent itself is the user's** — STT / LLM / TTS / voice / memory all live
  outside the app; Conduit is a thin, faithful audio pipe.
