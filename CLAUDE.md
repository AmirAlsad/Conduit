# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Conduit is a **bring-your-own-agent voice calling app** for iOS: a thin, faithful audio pipe that turns any voice agent you already run into a hands-free phone call you can take in the car. It rides **CallKit** (calls route through Bluetooth/CarPlay with no gatekept entitlement) and carries real-time audio over **WebRTC via the Pipecat iOS client** (Daily / LiveKit / SmallWebRTC transports). The agent — model, voice, persona, memory — is the user's own; Conduit never sits in the middle.

There is **no backend of ours, no Firebase, and no analytics.** Connection credentials are bring-your-own and live in the Keychain. Full vision, scope, and the CallKit↔WebRTC seam: [`docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md) and [`docs/CORE_SYSTEMS.md`](./docs/CORE_SYSTEMS.md) — read them before touching call/transport code.

The **call engine** — state machine, CallKit, PushKit, reconnection, ring-status receipts, and the Daily and LiveKit adapters — is a separate Swift package, **`ConduitCallEngine`**, extracted from this app. `project.yml` consumes it by version from `github.com/AmirAlsad/ConduitCallEngine` (`minorVersion: "0.2.0"`, i.e. 0.2.x only), pinned in the tracked `Package.resolved`. The app keeps agents and history, the Keychain, pairing, contacts, Siri, the SmallWebRTC adapter, and all UI, and reaches the engine through `Core/Services/AgentCalls/` (`Agent+CallTarget`, `AgentCallHost`). The package has its own `Sources/`, `Tests/`, and README; it is a separate checkout, so changes there are committed there.

A **self-hosted reference backend** — the agent side a developer runs under their own keys, *not* operated by us — lives in [`example-backend/`](./example-backend) (a self-contained Pipecat/FastAPI project with its own `CLAUDE.md`). It's reference code, not part of the iOS build.

## Build, Run & Test

Uses **XcodeBuildMCP** (configured at project scope in `.mcp.json`). **Load the `xcodebuildmcp` skill before your first build/test/run/UI-automation call** — it encodes pitfalls this section only summarizes. Defaults — `Conduit` scheme, `Debug`, and the session's simulator — are inferred, so most calls take no parameters; run `session_show_defaults` once per session to confirm. Local runs on this Mac use **iPhone 17 / iOS 27.2**; CI uses **iPhone 16 / iOS 18.6** (see the pin below).

**XcodeGen.** The `.xcodeproj` is generated from `project.yml` and is **gitignored** — a fresh clone must run `xcodegen generate` first. Re-run it after editing `project.yml` or adding/removing source files; plain edits to existing files don't need it. `xcodegen generate` also copies the tracked root `Package.resolved` into the generated project; that file pins the SDK versions, so change a pin deliberately.

**Engine package.** `ConduitCallEngine` resolves from GitHub by version like any other dependency; a fresh clone needs no sibling checkout. To work on both repos at once, temporarily swap the `ConduitCallEngine` entry in `project.yml` to `path: ../ConduitCallEngine` (a checkout next to this repo) and re-run `xcodegen generate`; don't commit that, and restore the URL entry before committing. **Trap:** a build with the local path rewrites the root `Package.resolved` without an engine pin; after restoring the URL entry, re-resolve and commit the new `Package.resolved`, and never commit the one a path build left behind. After any SDK or pin change, run `scripts/check-bundle.sh <path-to-Conduit.app>` (no second un-prefixed WebRTC next to Daily's) and regression-call Daily.

- **Build:** `build_sim` (Debug). Release → `extraArgs: ["-configuration", "Release"]`.
- **Test:** `test_sim`, **pinned to iPhone 17 / iOS 27.2 locally and iPhone 16 / iOS 18.6 in CI** (see pin below). Single test → `extraArgs: ["-only-testing", "ConduitTests/Suite/test"]`. Engine tests run in a `ConduitCallEngine` checkout: `xcodebuild -scheme ConduitCallEngine-Package -destination '<sim>' test`.
- Build nuances (clean policy), the flow-testing procedure, UI-verification steps, the reporting contract, and the shell fallback live in **[`docs/AGENT_WORKFLOW.md`](./docs/AGENT_WORKFLOW.md)** — read it before running or flow-testing the app.

> **Test sim pin.** CI (`.github/workflows/tests.yml`) builds with **Xcode 26.3** on `macos-15` (the app and engine package need the iOS 26 SDK) and runs tests on **iPhone 16 / iOS 18.6**, not the iOS 26 simulator, because iOS 26's accessibility subsystem reports the app frame as `0x0` with no children, so every XCUITest query times out though screens render fine. A failed build or test fails the CI job (the xcodebuild step sets `pipefail`). The development Mac's Xcode 27.2 can't install any iOS 18 runtime, so local runs there use **iPhone 17 / iOS 27.2**, where XCUITest queries were confirmed to work. Re-verify on future sim bumps.

**The testing reality:** the simulator can't run CallKit and the WebRTC client can't capture the mic there, so a real two-way call is **device-only**. Keep the CallKit and transport boundaries behind protocols so the logic underneath tests at sim speed. After non-trivial changes, run tests automatically using this scope:

| If you touched | Run |
|---|---|
| Engine code in the package (`CallEngine`, reconnection, hold, pre-connect, push/ring handling, cues and signals, the CallKit/audio seams, the Daily/LiveKit adapters' logic) | **The package's tests** (from a `ConduitCallEngine` checkout, against its fakes) — most call bugs live here; then build the app, and run `ConduitTests` if the engine's public surface changed |
| Host glue in `Core/Services/AgentCalls/` (`Agent+CallTarget`, `AgentCallHost`) | `ConduitTests/AgentCalls/` and `AppWiringTests` (they drive the engine through `CallEngine.simulated`, with `fireTimer` / `awaitPendingWork` for its timers and background work) |
| Connection/pairing parsing, transport selection, error handling, any pure logic/model in the app | **Unit tests on the sim** (`ConduitTests`) |
| One logic file in `Features/<X>/` | The `ConduitTests/` test(s) mapping to `<X>` |
| A cross-cutting service or app-wide state | The full `ConduitTests` unit suite |
| Transport adapters (package Daily/LiveKit, app SmallWebRTC), CallKit/PushKit boundary, audio-session activation, live-call lifecycle | **Device-only / manual (Layer 2–3)** — can't run in sim/CI (the pure pieces are the exception and have `ConduitTests`: `SmallWebRTCConnectionGate`, `SmallWebRTCAudioRouteGate`, `RouteAwareRingback`, `AudioPlayerRingback`, `RingbackMethod`). Build only; flag for on-device verification (`docs/DEVICE_VERIFICATION.md`) |
| Audio routing / two-way audio (earpiece↔speaker↔Bluetooth/car) | **Manual (Layer 3), AirPods or device** — flag it |
| Files in `ConduitUITests/` | The UITest(s) changed (iPhone 16 / iOS 18.6 in CI; iPhone 17 / iOS 27.2 locally) |
| Pure UI/copy/asset, or color/spacing-only SwiftUI; DEBUG-only tooling in `Debug/` (call trace, Cue Lab) | Skip tests; **build only** |
| `project.yml` / `Config/` / `Info.plist` | Build only (after `xcodegen generate` if `project.yml` changed) |
| Docs only (`.md`, comment-only) | **Nothing** |

When unsure which row applies, ask before running the full suite. (Coverage-gap vs. regression-backfill rules: see `docs/AGENT_WORKFLOW.md`.)

## Skills

Vendored under `.claude/skills/`; all but `xcodebuildmcp` are hash-pinned in `skills-lock.json`. Load the relevant one **before** touching the matching code (skip if already loaded this session):

- **`xcodebuildmcp`** — before any build/test/run/UI-automation action.
- **`swiftui-pro`** — before reading/writing/reviewing SwiftUI views.
- **`swift-testing-pro`** — before working on tests under `ConduitTests/` (or the package's `Tests/`).
- **`swift-architecture-skill`** — before introducing/refactoring architecture (state ownership, the CallKit/transport protocol boundaries).
- **`aso-appstore-screenshots`** — user-invocable (`/aso-appstore-screenshots`); generates App Store / Play Store marketing screenshots from benefit discovery → scaffold → AI enhancement. Needs Python `Pillow` + `openai` (`pip install -r` the skill's `requirements.txt`) and an `OPENAI_API_KEY` for the enhancement step. Writes `screenshots/` + `.aso/state.md` to the project root — both gitignored; never commit generated images or the key.

## Architecture (at a glance)

Three conceptual layers — keep the seams behind protocols so the logic stays testable:

1. **Call layer (CallKit)** — presents the agent session as a native call (system UI, Bluetooth/CarPlay routing, mute/end, lock screen). CallKit **owns** the audio session; media attaches on activation — WebRTC must never seize the mic itself. Lives in the package (`CallEngine`, `SystemCallProvider`, PushKit registration).
2. **Transport layer (WebRTC via the Pipecat iOS client)** — real-time audio to/from the agent behind the package's `CallTransport` protocol; transports swappable (Daily and LiveKit adapters in the package, SmallWebRTC in the app).
3. **The agent (theirs)** — STT, LLM, TTS, voice, memory. The app doesn't know or care which models are behind it.

The CallKit↔WebRTC handshake is the fiddliest seam and the most likely place to lose hours — treat the system as the session owner. The engine's seam protocols are package-internal; the app sees `CallEngine`, `CallEngineDelegate`, `CallTarget`, and `CallTransport`, and the package's `ConduitCallEngineTesting` product (`FakeTransport`, `SimulatedCallSystem`, `CallEngine.simulated(...)`) supplies the fakes for the simulator and tests.

### Project structure

```
Conduit/
├── App/                  # Entry point, AppDelegate, RootTabView
├── Core/
│   ├── Models/           # Agent, CallLogEntry (SwiftData), TransportKind, AgentColor
│   ├── Services/         # AppEnvironment (composition root); AgentCalls/ (engine glue), Transport/ (SmallWebRTC adapter),
│   │                     #   Keychain/, Contacts/, Persistence/, Pairing/, Audio/ (spoken state, microphone permission), Push/ (token registration,
│   │                     #   missed-call notification), Siri/, DeepLink/
│   └── Utilities/        # Log (os.log), AccessibilityID, constants
├── Features/             # Self-contained MVVM modules (Recents, Contacts, AgentDetail, AddEditAgent, InCall, Settings)
├── Shared/               # Reusable components, navigation
├── Debug/                # DEBUG-only: call trace, Cue Lab, device spikes
└── Resources/            # Assets, audio
ConduitTests/             # Host unit tests (agent glue, pairing, Siri, view models — run in sim)
ConduitUITests/           # UI tests (iPhone 16 / iOS 18.6 in CI)
ConduitCallEngine (package)  # Swift package consumed by version: the call engine
├── Sources/ConduitCallEngine/         # CallEngine, CallKit/, Push/, Transport/ (CallTransport + events), Models/
├── Sources/ConduitCallEngineDaily/    # PipecatDailyTransport
├── Sources/ConduitCallEngineLiveKit/  # LiveKitTransport
├── Sources/ConduitCallEngineTesting/  # FakeTransport, SimulatedCallSystem, CallEngine.simulated(...)
└── Tests/                             # Engine unit tests
```

> **Current state.** Built: outgoing and incoming calls (VoIP push → CallKit, ring-status receipts, missed-ring rows and notifications, ring timeouts and cancels, pre-connect while ringing) on **Daily, LiveKit and SmallWebRTC** (SmallWebRTC is LAN/self-hosted only); reconnection; the 30 s join deadline ("Agent didn't join"); the explicit microphone request; QR / `conduit://add-agent` pairing (`example-backend/scripts/pair.py`) and staged Test Connection; Siri dialing (App Intents + SiriKit, layers 1–2); Add to Contacts; all six `Features/` modules. All of it runs on engine 0.2.x through `AppEnvironment.live()` (in the simulator over `SimulatedCallSystem` and `FakeTransport`s).
>
> How a call sounds: the announcer speaks through the system's own speech session (`usesApplicationAudioSession = false`), and the ringback is route-aware (`RouteAwareRingback`: system sound at the ear, audio player on headset-type routes). Calls start on the earpiece (`defaultsToSpeaker` off). An incoming ring to a fixed-room (direct) agent without inline credentials is capped at the `credentials` pre-connect tier. **No call hold:** the engine's hold is an experimental opt-in the app leaves off, so a phone call the user accepts ends the call. LiveKit runs in manual audio mode, so its native call-screen route button works; Daily's does not (`bugs.md`). SmallWebRTC uses our fork `AmirAlsad/pipecat-client-ios-small-webrtc@livekit-webrtc` (built against LiveKitWebRTC; the stock stasel/WebRTC crashed every Daily call), an app-only dependency.
>
> **Device verification** last ran on **2026-11-12** (iPhone 17, iOS 27.0, engine 0.2.0 from the package's local `main`, all three transports). What passed, on what, and what was not run is the Results block of [`docs/DEVICE_VERIFICATION.md`](./docs/DEVICE_VERIFICATION.md); quote nothing as verified beyond it. Not yet exercised on a device: a phone call ending the call on the final build, Focus-filtered rings (iOS 27.0 did not filter), the SiriKit contact path, an incoming call on AirPods, CarPlay and wired routes. Open follow-ups (hold for a real phone call, same room on reconnect, and others) and the milestone history are in [`docs/ROADMAP.md`](./docs/ROADMAP.md). The published docs site (`mkdocs.yml`, `.github/workflows/docs.yml`) is linked from the app through `Core/Utilities/ExternalLinks.swift` — keep `mkdocs.yml` nav slugs, page anchors and `ExternalLinks` in sync.

## Conventions

- **Logging:** pure `os.log` via `Core/Utilities/Log.swift` — `Log.info(.call, "…")`, `Log.error(.transport, "…\(error)")`. No analytics or crash SDK.
- **AccessibilityID:** every interactive element gets a stable `<Feature>_<Element>` id (one `AccessibilityID+<Feature>.swift` per feature). Automation/tests query by identifier, **never** raw coordinates; flag missing identifiers instead of tapping by coordinate.
- Fuller conventions in [`docs/CONVENTIONS.md`](./docs/CONVENTIONS.md); doc index + load order in [`docs/README.md`](./docs/README.md).

## Code hygiene

- **Scope discipline.** Don't add features, refactor, or abstract beyond the task. Three similar lines beats a premature abstraction. No half-finished work — surface blockages.
- **Comments.** Default to none; well-named identifiers self-document. When you must, explain WHY (a constraint, invariant, workaround), never WHAT, and never reference the task/callers ("added for X") — that context rots.
- **Dead code.** Remove it, don't comment it out; also drop backwards-compat shims and `// removed:` markers.
- **Dependencies.** No new SPM dependencies without explicit approval — propose first. The `ConduitCallEngine` core target imports no transport SDK, and neither the SmallWebRTC fork nor stasel/WebRTC may enter the package (a second un-prefixed WebRTC next to Daily's crashes every Daily call). SDK pins live in the tracked root `Package.resolved`.
- **Git workflow.** Solo repo — commit and push **directly to `main`** when asked. Don't create feature branches or open PRs for routine work.
- **No backend / Firebase / analytics.** Never introduce any. Credentials are user-supplied, live in the Keychain, and never touch a contact, a log, or source control.
- **Don't** launch the sim for pure code changes, `clean` reflexively, commit secrets or the generated `Conduit.xcodeproj`, or write screenshots/logs into the repo (those go to `/tmp/`).

## Project memory

`potential_skills/` is project-local memory for recurring blind spots — bugs that bite the same way 2+ times. Before working in a domain that has a `potential_skills/<domain>.md`, read it first. When you hit a bug: check `potential_skills/` → check `bugs.md` (the tracked project bug log) → fix → log it in `bugs.md` → promote to a `potential_skills/<domain>.md` file on the 2nd occurrence. Format + lifecycle: `potential_skills/README.md`.

## Documentation

Update the relevant `docs/` file after architectural changes, new features, modified services, or pattern changes (skip for small fixes / UI tweaks). Index + load order: [`docs/README.md`](./docs/README.md).
