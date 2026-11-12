# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Conduit is a **bring-your-own-agent voice calling app** for iOS: a thin, faithful audio pipe that turns any voice agent you already run into a hands-free phone call you can take in the car. It rides **CallKit** (calls route through Bluetooth/CarPlay with no gatekept entitlement) and carries real-time audio over **WebRTC via the Pipecat iOS client** (Daily / LiveKit / SmallWebRTC transports). The agent — model, voice, persona, memory — is the user's own; Conduit never sits in the middle.

There is **no backend of ours, no Firebase, and no analytics.** Connection credentials are bring-your-own and live in the Keychain. Full vision, scope, and the CallKit↔WebRTC seam: [`docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md) and [`docs/CORE_SYSTEMS.md`](./docs/CORE_SYSTEMS.md) — read them before touching call/transport code.

The **call engine** — state machine, CallKit, PushKit, reconnection, ring-status receipts, and the Daily and LiveKit adapters — is a separate Swift package, **`ConduitCallEngine`**, extracted from this app. `project.yml` consumes it by version from `github.com/AmirAlsad/ConduitCallEngine` (`minorVersion: "0.2.0"`, i.e. 0.2.x only), pinned in the tracked `Package.resolved`. The app keeps agents and history, the Keychain, pairing, contacts, Siri, the SmallWebRTC adapter, and all UI, and reaches the engine through `Core/Services/AgentCalls/` (`Agent+CallTarget`, `AgentCallHost`). The package has its own `Sources/`, `Tests/`, and README; it is a separate checkout, so changes there are committed there.

A **self-hosted reference backend** — the agent side a developer runs under their own keys, *not* operated by us — lives in [`example-backend/`](./example-backend) (a self-contained Pipecat/FastAPI project with its own `CLAUDE.md`). It's reference code, not part of the iOS build.

## Build, Run & Test

Uses **XcodeBuildMCP** (configured at project scope in `.mcp.json`). **Load the `xcodebuildmcp` skill before your first build/test/run/UI-automation call** — it encodes pitfalls this section only summarizes. Defaults — `Conduit` scheme, `iPhone 16` / iOS 18.6 simulator, `Debug` — are inferred, so most calls take no parameters; run `session_show_defaults` once per session to confirm.

**XcodeGen.** The `.xcodeproj` is generated from `project.yml` and is **gitignored** — a fresh clone must run `xcodegen generate` first. Re-run it after editing `project.yml` or adding/removing source files; plain edits to existing files don't need it. `xcodegen generate` also copies the tracked root `Package.resolved` into the generated project; that file pins the SDK versions, so change a pin deliberately.

**Engine package.** `ConduitCallEngine` resolves from GitHub by version like any other dependency; a fresh clone needs no sibling checkout. To work on both repos at once, temporarily swap the `ConduitCallEngine` entry in `project.yml` to `path: ../ConduitCallEngine` (a checkout next to this repo) and re-run `xcodegen generate`; don't commit that, and restore the URL entry before committing. After any SDK or pin change, run `scripts/check-bundle.sh <path-to-Conduit.app>` (no second un-prefixed WebRTC next to Daily's) and regression-call Daily.

- **Build:** `build_sim` (Debug). Release → `extraArgs: ["-configuration", "Release"]`.
- **Test:** `test_sim`, **pinned to iPhone 16 / iOS 18.6** (see pin below). Single test → `extraArgs: ["-only-testing", "ConduitTests/Suite/test"]`. Engine tests run in a `ConduitCallEngine` checkout: `xcodebuild -scheme ConduitCallEngine-Package -destination '<sim>' test`.
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
| Transport adapters (package Daily/LiveKit, app SmallWebRTC), CallKit/PushKit boundary, audio-session activation, live-call lifecycle | **Device-only / manual (Layer 2–3)** — can't run in sim/CI (the pure `SmallWebRTCConnectionGate` is the exception: `ConduitTests`). Build only; flag for on-device verification (`docs/DEVICE_VERIFICATION.md`) |
| Audio routing / two-way audio (earpiece↔speaker↔Bluetooth/car) | **Manual (Layer 3), AirPods or device** — flag it |
| Files in `ConduitUITests/` | The UITest(s) changed (iPhone 16 / iOS 18.6) |
| Pure UI/copy/asset, or color/spacing-only SwiftUI; DEBUG-only tooling in `Debug/` (call trace, Cue Lab) | Skip tests; **build only** |
| `project.yml` / `Config/` / `Info.plist` | Build only (after `xcodegen generate` if `project.yml` changed) |
| Docs only (`.md`, comment-only) | **Nothing** |

When unsure which row applies, ask before running the full suite. (Coverage-gap vs. regression-backfill rules: see `docs/AGENT_WORKFLOW.md`.)

## Skills

Vendored and hash-pinned in `skills-lock.json` under `.claude/skills/`. Load the relevant one **before** touching the matching code (skip if already loaded this session):

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

> **Current state.** The app is built through **M6**: the M0 foundation (protocol seams + fakes, SwiftData models, `AppEnvironment`), the M1 call state machine (`CallEngine`, reconnection, spoken state), the real Daily transport (M2), the CallKit + audio-session seam (M3), the Keychain real + permission-free Add-to-Contacts (WS-4 + follow-ups), all six `Features/` modules + `Shared/` components (WS-5), the device-verified M5 realistic target (pairing call, two-way audio, mute, in-app routing, contact enrichment), and the native **LiveKit** transport (M6) — wired through `AppEnvironment.live()` (persistent store + real services; in the simulator the engine runs over `SimulatedCallSystem` with `FakeTransport`s). **The engine itself now lives in the `ConduitCallEngine` package** (see Project Overview); the app keeps spoken state and ringback, the missed-call notification, Siri, and token registration, joined to the engine by `AgentCallHost`. LiveKit uses manual audio (`AudioManager.setEngineAvailability` gated on CallKit), so on LiveKit calls the **native call-screen route button works** (Daily can't — see `bugs.md`). Since M6: Recents **swipe-to-delete**; an **audio-interruption seam** (`AudioInterruptionObserving`) that pauses/resumes the mic on Siri/phone-call/nav takeovers; and **agent-initiated inbound calls** (VoIP push → CallKit → answer → reuse the outgoing connect path; see [`docs/INBOUND_CALLS.md`](./docs/INBOUND_CALLS.md)) — with **ring-status receipts** (a `status_url` in the push makes the engine POST back the ring's outcome — answered / declined / busy / suppressed_by_focus / unanswered / canceled; `RingStatusReporting` seam, `/inbound/status` on the reference backend) and token registration on agent **save** as well as launch (`InboundRegistering`). Live interruption/ducking audio remains **device-only/unverified**. The **LiveKit path is device-verified** (pairing connect, two-way audio, native route button, reconnection — against the deployed reference engine, June 2026), and the **inbound path is device-verified end-to-end** (June 2026, LiveKit **and Daily** agents — including ring-status receipts, toggle-save registration, unknown-agent graceful end, and immediate end-call teardown on hangup): cold ring → answer → two-way audio, decline → Recents, inline creds, Focus/DND-filtered rings logged as missed with a quiet local notification (`MissedCallNotifier`, provisional auth), busy pushes report-then-end (a silently ignored VoIP push gets the app killed — see `bugs.md`), and rings surviving a backend redeploy (volume-backed registry). The reference engine's inbound stack (APNs sender, `/inbound/register`, `/admin/ring`, `scripts/ring.py`) lives in `example-backend/`. **M8 (developer on-ramp) is built**: `conduit://add-agent` deep links (`DeepLinkParser`, scheme in `Info.plist`, routed via `AppEnvironment.pendingAgentLink` → Contacts tab; re-scan of a known pairing endpoint opens Edit) with `scripts/pair.py` printing the link + terminal QR (key embedded by default — the link is then a secret); a **staged Test Connection** checklist (pairing → credentials → transport → ready, injectable `pairingResolver` seam); **persisted failure reasons** (`CallLogEntry.failureReasonRaw` → "Failed — authentication" rows + an in-call hint); and **decluttered one-line footers** linking to the published `docs/using-conduit.md`. Device-verified June 2026 (Camera-scan QR → prefilled sheet → staged diagnostics against the deployed engine; migration sane over existing history). **M9 (SmallWebRTC) is built and device-verified**: `TransportKind.smallwebrtc` + `PipecatSmallWebRTCTransport` (a host-written `CallTransport`, Daily-adapter mirror; pairing returns the engine's offer URL + a short-lived bearer as `room_url`/`token`, `PairingClient` unchanged), the reference backend's `POST/PATCH /webrtc/{agent_id}/offer` running **in-process bots** (offer = rendezvous; dropped peer → immediate `end_now`; `run_bot` gained `handle_sigterm`), and the zero-cloud LAN path (`pair.py --transport smallwebrtc`, `NSLocalNetworkUsageDescription` for the iOS local-network prompt). **Critical:** the stock package's stasel/WebRTC collides with Daily's embedded WebRTC (un-prefixed `RTC*` duplicated → every Daily call crashed; see `bugs.md`), so `project.yml` pins **our fork** `AmirAlsad/pipecat-client-ios-small-webrtc@livekit-webrtc` built against `LiveKitWebRTC` (typealias shim; upstream issue pipecat-client-ios-small-webrtc#6) — an **app-only** dependency that must never enter the engine package. After any transport-SDK bump, run `scripts/check-bundle.sh` on the device bundle (no stasel `WebRTC.framework`) and regression-call Daily. SmallWebRTC is LAN/self-hosted-only (UDP media — not Railway); verified over hotspot LAN: pairing → two-way audio → clean RTVI end-call → instant teardown, with Daily + LiveKit regression calls green in the same binary. **M10 Siri dialing (layers 1–2) is built** (`Core/Services/Siri/`: App Intents + SiriKit, both funneling through `AppEnvironment.pendingSiriCall`, consumed by `RootTabView` only at `scenePhase == .active`): device-verified unlocked on both layers, SiriKit also dials from the lock screen. `CallAgentIntent`/`agent` parameter names are frozen for the iOS 27 `.phone.startCall` schema adoption (layer 3 — needs the Xcode 27 SDK; in-car steering-wheel verification also outstanding). See [`docs/CORE_SYSTEMS.md`](./docs/CORE_SYSTEMS.md). The repo is **public**, with a user-facing **docs site** (MkDocs Material → GitHub Pages via `.github/workflows/docs.yml`; published pages listed in `docs/README.md`) that the app links to through `Core/Utilities/ExternalLinks.swift` — keep `mkdocs.yml` nav slugs and `ExternalLinks` in sync. `PairingClient` accepts `url` as a room-URL fallback key, and the reference backend's per-agent routes (`/connect/{agent_id}`) match the contract's "endpoint identifies the agent" model. The app on `ConduitCallEngine` **0.1.1** was **device-verified in November 2026** (Daily, LiveKit, SmallWebRTC; outgoing, inbound, reconnection); what passed, what could not be exercised (Focus-filtered rings, call hold, the SiriKit contact path) and the open follow-ups are recorded in `docs/DEVICE_VERIFICATION.md` and `docs/ROADMAP.md`. Every "device-verified" above is scoped to the state it names (June / November 2026, engine 0.1.x and the SDKs of the time). **Engine 0.2.x adoption is built and unit-tested; device verification is pending (a session is planned; none has run).** It brought: the SDK bumps (Pipecat 1.3.0, Daily 0.41.0, LiveKit 2.19.0; reference backend on pipecat-ai 1.4.0); the engine's cue events driving the spoken cues in `AgentCallHost`; every missed ring recorded with its reason (ring timeout, sender cancel) plus a notification; **call hold** (CallKit and an in-call control; `call-held` / `call-resumed` to the agent, with delivery results and retries); **pre-connect** while ringing (a `ring` object in the pairing body; LiveKit and Daily join during the ring, Daily with the agent's audio unsubscribed until the answer, SmallWebRTC credentials only; an answered call is never held for the outgoing minimum and gets no ringback: nothing when its agent was there at the answer, "Connecting" once if it is still connecting a second later); `call-answered`; a 30 s join deadline ("Agent didn't join"); an explicit microphone request before calls and when inbound is turned on; `push_features` at token registration; the SmallWebRTC adapter rebuilt around a connection gate; and DEBUG tooling (a launch-spanning call trace carrying the engine's log events; the **Cue Lab**, `Debug/CueLab/`). The reference backend gained the matching ring tracker, cancel endpoint, await-answer/hold gates and a `tone` test agent. Spoken cues were inaudible on Daily calls and in the last retry phase of a LiveKit outage on the 0.1.1 run; the cause is unknown, the Cue Lab exists to find it, and the announcer's audio mechanism is unchanged. Treat hold, pre-connect, cancel, the new SDK versions (including their regression calls on all three transports) and the cue behaviour as unverified on a device until the 0.2.0 sheet in `docs/DEVICE_VERIFICATION.md` is filled in.

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

`potential_skills/` is project-local memory for recurring blind spots — bugs that bite the same way 2+ times. Before working in a domain that has a `potential_skills/<domain>.md`, read it first. When you hit a bug: check `potential_skills/` → check `bugs.md` (your auto-memory) → fix → log it in `bugs.md` → promote to a `potential_skills/<domain>.md` file on the 2nd occurrence. Format + lifecycle: `potential_skills/README.md`.

## Documentation

Update the relevant `docs/` file after architectural changes, new features, modified services, or pattern changes (skip for small fixes / UI tweaks). Index + load order: [`docs/README.md`](./docs/README.md).
