# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Conduit is a **bring-your-own-agent voice calling app** for iOS: a thin, faithful audio pipe that turns any voice agent you already run into a hands-free phone call you can take in the car. It rides **CallKit** (calls route through Bluetooth/CarPlay with no gatekept entitlement) and carries real-time audio over **WebRTC via the Pipecat iOS client** (Daily / LiveKit transports). The agent — model, voice, persona, memory — is the user's own; Conduit never sits in the middle.

There is **no backend of ours, no Firebase, and no analytics.** Connection credentials are bring-your-own and live in the Keychain. Full vision, scope, and the CallKit↔WebRTC seam: [`docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md) and [`docs/CORE_SYSTEMS.md`](./docs/CORE_SYSTEMS.md) — read them before touching call/transport code.

A **self-hosted reference backend** — the agent side a developer runs under their own keys, *not* operated by us — lives in [`example-backend/`](./example-backend) (a self-contained Pipecat/FastAPI project with its own `CLAUDE.md`). It's reference code, not part of the iOS build.

## Build, Run & Test

Uses **XcodeBuildMCP** (configured at project scope in `.mcp.json`). **Load the `xcodebuildmcp` skill before your first build/test/run/UI-automation call** — it encodes pitfalls this section only summarizes. Defaults — `Conduit` scheme, `iPhone 16` / iOS 18.6 simulator, `Debug` — are inferred, so most calls take no parameters; run `session_show_defaults` once per session to confirm.

**XcodeGen.** The `.xcodeproj` is generated from `project.yml` and is **gitignored** — a fresh clone must run `xcodegen generate` first. Re-run it after editing `project.yml` or adding/removing source files; plain edits to existing files don't need it.

- **Build:** `build_sim` (Debug). Release → `extraArgs: ["-configuration", "Release"]`.
- **Test:** `test_sim`, **pinned to iPhone 16 / iOS 18.6** (see pin below). Single test → `extraArgs: ["-only-testing", "ConduitTests/Suite/test"]`.
- Build nuances (clean policy), the flow-testing procedure, UI-verification steps, the reporting contract, and the shell fallback live in **[`docs/AGENT_WORKFLOW.md`](./docs/AGENT_WORKFLOW.md)** — read it before running or flow-testing the app.

> **Test sim pin.** Run tests on **iPhone 16 / iOS 18.6**, not the latest (iOS 26) simulator: iOS 26's accessibility subsystem reports the app frame as `0x0` with no children, so every XCUITest query times out though screens render fine. Re-verify on future sim bumps.

**The testing reality:** the simulator can't run CallKit and the WebRTC client can't capture the mic there, so a real two-way call is **device-only**. Keep the CallKit and transport boundaries behind protocols so the logic underneath tests at sim speed. After non-trivial changes, run tests automatically using this scope:

| If you touched | Run |
|---|---|
| Call state machine, connection/pairing parsing, transport selection, error handling, any pure logic/model | **Unit tests on the sim** (against fakes for the CallKit/transport protocols) — most bugs live here |
| One logic file in `Features/<X>/` | The `ConduitTests/` test(s) mapping to `<X>` |
| A cross-cutting service or app-wide state | The full `ConduitTests` unit suite |
| Transport layer, CallKit boundary, audio-session activation, live-call lifecycle | **Device-only / manual (Layer 2–3)** — can't run in sim/CI. Build only; flag for on-device verification |
| Audio routing / two-way audio (earpiece↔speaker↔Bluetooth/car) | **Manual (Layer 3), AirPods or device** — flag it |
| Files in `ConduitUITests/` | The UITest(s) changed (iPhone 16 / iOS 18.6) |
| Pure UI/copy/asset, or color/spacing-only SwiftUI | Skip tests; **build only** |
| `project.yml` / `Config/` / `Info.plist` | Build only (after `xcodegen generate` if `project.yml` changed) |
| Docs only (`.md`, comment-only) | **Nothing** |

When unsure which row applies, ask before running the full suite. (Coverage-gap vs. regression-backfill rules: see `docs/AGENT_WORKFLOW.md`.)

## Skills

Vendored and hash-pinned in `skills-lock.json` under `.claude/skills/`. Load the relevant one **before** touching the matching code (skip if already loaded this session):

- **`xcodebuildmcp`** — before any build/test/run/UI-automation action.
- **`swiftui-pro`** — before reading/writing/reviewing SwiftUI views.
- **`swift-testing-pro`** — before working on tests under `ConduitTests/`.
- **`swift-architecture-skill`** — before introducing/refactoring architecture (state ownership, the CallKit/transport protocol boundaries).

## Architecture (at a glance)

Three conceptual layers — keep the seams behind protocols so the logic stays testable:

1. **Call layer (CallKit)** — presents the agent session as a native call (system UI, Bluetooth/CarPlay routing, mute/end, lock screen). CallKit **owns** the audio session; media attaches on activation — WebRTC must never seize the mic itself.
2. **Transport layer (WebRTC via the Pipecat iOS client)** — real-time audio to/from the agent; transports swappable (Daily, LiveKit; SmallWebRTC later).
3. **The agent (theirs)** — STT, LLM, TTS, voice, memory. The app doesn't know or care which models are behind it.

The CallKit↔WebRTC handshake is the fiddliest seam and the most likely place to lose hours — treat the system as the session owner.

### Project structure

```
Conduit/
├── App/                  # Entry point, RootView, global app state
├── Core/
│   ├── Models/           # Domain models (Agent, Call, Connection)
│   ├── Services/         # CallKit, transport (Pipecat/WebRTC), contacts mirror, keychain
│   └── Utilities/        # Log (os.log), AccessibilityID, constants
├── Features/             # Self-contained MVVM modules (Recents, Contacts, AgentDetail, AddAgent, InCall, Settings)
├── Shared/               # Reusable components, navigation
└── Resources/            # Assets, audio
ConduitTests/             # Unit tests (logic, state machines, parsing — run in sim)
ConduitUITests/           # UI tests (iPhone 16 / iOS 18.6)
```

> **Current state.** The app is built through **M6**: the M0 foundation (protocol seams + fakes, SwiftData models, `AppEnvironment`), the M1 call state machine (`CallSessionCoordinator`, reconnection, spoken state), the real Daily transport (M2), the CallKit + audio-session seam (M3), the Keychain real + permission-free Add-to-Contacts (WS-4 + follow-ups), all six `Features/` modules + `Shared/` components (WS-5), the device-verified M5 realistic target (pairing call, two-way audio, mute, in-app routing, contact enrichment), and the native **LiveKit** transport (M6) — wired through `AppEnvironment.live()` (persistent store + real services; CallKit/Daily/LiveKit fall back to fakes in the simulator). LiveKit uses manual audio (`AudioManager.setEngineAvailability` gated on CallKit), so on LiveKit calls the **native call-screen route button works** (Daily can't — see `bugs.md`). Since M6: Recents **swipe-to-delete**; an **audio-interruption seam** (`AudioInterruptionObserving`) that pauses/resumes the mic on Siri/phone-call/nav takeovers; and **agent-initiated inbound calls** (VoIP push → CallKit → answer → reuse the outgoing connect path; see [`docs/INBOUND_CALLS.md`](./docs/INBOUND_CALLS.md)) — with **ring-status receipts** (a `status_url` in the push makes the app POST back answered / declined / busy / suppressed_by_focus; `RingStatusReporting` seam, `/inbound/status` on the engine) and token registration on agent **save** as well as launch (`InboundRegistering`). Live interruption/ducking audio remains **device-only/unverified**. The **LiveKit path is device-verified** (pairing connect, two-way audio, native route button, reconnection — against the deployed reference engine, June 2026), and the **inbound path is device-verified end-to-end** (June 2026, LiveKit **and Daily** agents — including ring-status receipts, toggle-save registration, unknown-agent graceful end, and immediate end-call teardown on hangup): cold ring → answer → two-way audio, decline → Recents, inline creds, Focus/DND-filtered rings logged as missed with a quiet local notification (`MissedCallNotifier`, provisional auth), busy pushes report-then-end (a silently ignored VoIP push gets the app killed — see `bugs.md`), and rings surviving a backend redeploy (volume-backed registry). The reference engine's inbound stack (APNs sender, `/inbound/register`, `/admin/ring`, `scripts/ring.py`) lives in `example-backend/`. See [`docs/CORE_SYSTEMS.md`](./docs/CORE_SYSTEMS.md). The repo is **public**, with a user-facing **docs site** (MkDocs Material → GitHub Pages via `.github/workflows/docs.yml`; published pages listed in `docs/README.md`) that the app links to through `Core/Utilities/ExternalLinks.swift` — keep `mkdocs.yml` nav slugs and `ExternalLinks` in sync. `PairingClient` accepts `url` as a room-URL fallback key, and the reference backend's per-agent routes (`/connect/{agent_id}`) match the contract's "endpoint identifies the agent" model.

## Conventions

- **Logging:** pure `os.log` via `Core/Utilities/Log.swift` — `Log.info(.call, "…")`, `Log.error(.transport, "…\(error)")`. No analytics or crash SDK.
- **AccessibilityID:** every interactive element gets a stable `<Feature>_<Element>` id (one `AccessibilityID+<Feature>.swift` per feature). Automation/tests query by identifier, **never** raw coordinates; flag missing identifiers instead of tapping by coordinate.
- Fuller conventions in [`docs/CONVENTIONS.md`](./docs/CONVENTIONS.md); doc index + load order in [`docs/README.md`](./docs/README.md).

## Code hygiene

- **Scope discipline.** Don't add features, refactor, or abstract beyond the task. Three similar lines beats a premature abstraction. No half-finished work — surface blockages.
- **Comments.** Default to none; well-named identifiers self-document. When you must, explain WHY (a constraint, invariant, workaround), never WHAT, and never reference the task/callers ("added for X") — that context rots.
- **Dead code.** Remove it, don't comment it out; also drop backwards-compat shims and `// removed:` markers.
- **Dependencies.** No new SPM dependencies without explicit approval — propose first.
- **Git workflow.** Solo repo — commit and push **directly to `main`** when asked. Don't create feature branches or open PRs for routine work.
- **No backend / Firebase / analytics.** Never introduce any. Credentials are user-supplied, live in the Keychain, and never touch a contact, a log, or source control.
- **Don't** launch the sim for pure code changes, `clean` reflexively, commit secrets or the generated `Conduit.xcodeproj`, or write screenshots/logs into the repo (those go to `/tmp/`).

## Project memory

`potential_skills/` is project-local memory for recurring blind spots — bugs that bite the same way 2+ times. Before working in a domain that has a `potential_skills/<domain>.md`, read it first. When you hit a bug: check `potential_skills/` → check `bugs.md` (your auto-memory) → fix → log it in `bugs.md` → promote to a `potential_skills/<domain>.md` file on the 2nd occurrence. Format + lifecycle: `potential_skills/README.md`.

## Documentation

Update the relevant `docs/` file after architectural changes, new features, modified services, or pattern changes (skip for small fixes / UI tweaks). Index + load order: [`docs/README.md`](./docs/README.md).
