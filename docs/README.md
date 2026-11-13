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
| [ARCHITECTURE](./ARCHITECTURE.md) | The three-layer model (CallKit / WebRTC transport / the user's agent), folder structure (the app and the `ConduitCallEngine` package), the key seams. |
| [CONVENTIONS](./CONVENTIONS.md) | Code style, naming, AccessibilityID convention, the per-developer build override model, logging standards. |
| [CORE_SYSTEMS](./CORE_SYSTEMS.md) | Shared infrastructure: what lives in the `ConduitCallEngine` package vs. the app, the protocol seams + fakes, SwiftData models, AppEnvironment, the call state machine, reconnection/spoken state, the audio-session/CallKit wiring, audio-interruption handling, why calls are not held, pre-connect, and the inbound-call path. |
| [CONNECTION_CONTRACT](./CONNECTION_CONTRACT.md) | How a user's agent backend connects to Conduit — the pairing-endpoint request/response shapes, the direct-room fallback, and the call-lifecycle expectations (grace window, the end-call signal). Hand this to whoever runs the agent. *(published)* |
| [INBOUND_CALLS](./INBOUND_CALLS.md) | How a user's own server rings the user through Conduit (agent-initiated VoIP-push calls) — token registration/unregistration, the push payload, ring timeouts and cancels, pre-connect, the call-control messages (`call-connected`, `call-held`, `call-resumed`) and when the agent should start speaking, and ring-status receipts. The inbound companion to the connection contract. *(published)* |
| [AGENT_WORKFLOW](./AGENT_WORKFLOW.md) | Operational playbook for agents driving the app: build nuances, UI verification, flow testing, the reporting contract, and the shell fallback. |
| [DEVICE_VERIFICATION](./DEVICE_VERIFICATION.md) | The by-hand run sheet for everything the simulator can't run (real calls, routing, rings, Siri), used for before/after runs around call-stack changes and transport-SDK bumps, with the record of each run (the latest: the engine 0.2.0 session of 2026-11-12) and what it did not cover. |
| [index](./index.md) | Landing page of the published docs site. *(published)* |
| [using-conduit](./using-conduit.md) | The user guide: push-to-talk, where the sound comes from, what you hear on a call, Siri, calls from your agent, missed calls, microphone access, Add to Contacts, privacy. Several sections are linked from a "Learn more" in the app (`ExternalLinks.swift`). *(published)* |
| [privacy](./privacy.md) | The privacy policy: what the app sends where (credentials, registration, ring outcomes, call audio), and what it never collects. *(published)* |
| [connect-your-agent](./connect-your-agent.md) | User-facing orientation: pairing vs. direct, one endpoint per agent, where the example backend fits. *(published)* |
| [backend/quickstart](./backend/quickstart.md) | Run the example backend and point the app at it. *(published)* |
| [backend/bring-your-own-pipeline](./backend/bring-your-own-pipeline.md) | Swap your own agent pipeline into the example backend. *(published)* |
| [backend/direct-mode](./backend/direct-mode.md) | Direct credentials, the provision script, and the Daily/LiveKit webhooks. *(published)* |
| [backend/inbound-calls](./backend/inbound-calls.md) | Ringing the user from the example backend (APNs setup, registration, `ring.py`). *(published)* |
| [backend/deploy](./backend/deploy.md) | Deploying the example backend (Docker, Railway, post-deploy steps). *(published)* |

**The docs site.** Pages marked *(published)* are built into the public site at
<https://amiralsad.github.io/Conduit/> by `mkdocs.yml` (Material theme, deployed by
`.github/workflows/docs.yml` on push to `main`). Everything else in `docs/` is
internal development documentation, kept off the site via `exclude_docs`. The app
links to the published pages through `Core/Utilities/ExternalLinks.swift` — if a
published page's filename changes, update both the `nav` and `ExternalLinks`.

## Load Order for Agents

These docs are written to be fed to an agent as context. Load them in order so
each builds on the last instead of grepping blindly:

1. **`ARCHITECTURE.md`** first — understand the three-layer model and the
   CallKit↔WebRTC seam before touching anything.
2. **`CONVENTIONS.md`** next — house style, naming, the AccessibilityID and build
   override rules you must follow.
3. **`CORE_SYSTEMS.md`** for shared infrastructure (call/transport/audio/reconnect)
   and the feature surfaces (the in-call screen, Siri dialing).

## Project Facts (orientation)

- **Build:** XcodeGen. `project.yml` is the source of truth; the `.xcodeproj` is
  generated and gitignored, so you must run `xcodegen generate` after any
  `project.yml` change or fresh clone. Scheme: `Conduit`. The `ConduitCallEngine`
  package resolves from GitHub by version like the other dependencies.
  The tracked root `Package.resolved` pins the SDKs.
- **Structure:** `Conduit/{App, Core, Features, Shared, Debug, Resources}` (`Debug/` is DEBUG-only tooling); the call
  engine lives in the `ConduitCallEngine` package (state machine, CallKit,
  PushKit, Daily/LiveKit adapters, fakes), the app keeps agents, history, pairing,
  the SmallWebRTC adapter, Siri, and the UI.
- **Testing pin:** CI runs iPhone 16 / iOS 18.6 (the iOS 26 sim has a broken
  accessibility subsystem). A Mac whose Xcode can't install an iOS 18 runtime runs
  iPhone 17 / iOS 27.2 locally, where XCUITest queries were confirmed to work.
  Engine tests run in the package; host tests in `ConduitTests`. Core CallKit +
  WebRTC live calls are device-only; CI covers logic/unit + UI smoke only.
- **Decisions:** no backend, no Firebase, no analytics. Logging goes through the
  `Log` utility (os.log) in `Core/Utilities`.

## Key Technologies

- **SwiftUI** — declarative UI (`@Observable`, async/await).
- **CallKit** — presents the agent session as a native call and owns the audio session.
- **ConduitCallEngine** — the Swift package holding the call engine (state machine,
  CallKit, PushKit, reconnection, Daily/LiveKit adapters, fakes).
- **WebRTC via the Pipecat iOS client** — real-time transport to the agent
  (Daily / LiveKit / SmallWebRTC transports, swappable).
- **The agent itself is the user's** — STT / LLM / TTS / voice / memory all live
  outside the app; Conduit is a thin, faithful audio pipe.
