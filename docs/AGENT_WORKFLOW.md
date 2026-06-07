# Agent Workflow — Run, Flow-Test & Report

The on-demand operational playbook for agents driving the Conduit app. `CLAUDE.md`
carries the always-loaded essentials (build/test defaults, the test-scope table,
the "Don't" rules); this file holds the detailed procedures: build nuances, UI
verification, flow testing, the reporting contract, and the shell fallback. Load
it when you're about to run or flow-test the app.

## Building (nuances)

Use `build_sim` as the default. Fix all build errors before any simulator
interaction, and don't launch the simulator just to verify a build. For Release
builds (TestFlight, archive verification), pass `extraArgs: ["-configuration",
"Release"]`; everything else stays Debug.

Don't `clean` reflexively — it costs minutes. Reach for it only after `xcodegen
generate`, after dependency or `Config/` changes, or when symptoms match
cached-artifact failure (mysterious link errors, "module compiled with different
version").

## UI verification & the AccessibilityID rule

When asked to verify how something looks or to run the app:
build → launch → navigate to the relevant screen → screenshot.

- Use the UI snapshot/describe tool to orient before tapping. **Identifiers are
  far more reliable than coordinates.**
- Every interactive element gets a stable `<Feature>_<Element>` accessibility
  identifier (e.g. `Recents_CallButton`, `AgentDetail_CallButton`,
  `AddAgent_TestConnectionButton`). Automation and tests query by identifier,
  **never** by raw coordinates.
- If an element is missing an identifier, **flag it** (name the element + its
  parent) instead of silently tapping by coordinate. Let the human decide whether
  to add it.

## Flow testing & what the simulator can't do

When asked to test a flow (add-agent sheet, Recents, Agent Detail, in-call
screen), step through it end-to-end. The goal is **exploration** — surface bugs
and friction, not pass/fail.

- **Capture logs by default** for any call/transport/audio flow
  (`launch_app_logs_sim` over `launch_app_sim`); surface notable `Log.error` /
  `Log.warning` lines. Voice and audio behavior shows up in logs before it shows
  on screen.
- **Don't simulate what the simulator can't.** CallKit, real-mic capture, and a
  real two-way WebRTC call do not work in the simulator. A CallKit-free debug path
  that joins a room and plays *inbound* audio can validate connect-and-downlink in
  the sim, but never a full conversation. Test what you can, then explicitly say
  what you couldn't and ask for device verification (Layer 2 tethered-device
  tests, Layer 3 AirPods/speaker routing).
- **Save artifacts to `/tmp/`** with descriptive names (e.g.
  `/tmp/conduit_flow_addagent_2026-06-07.png`). Inline a one-line description of
  each in your reply; never write screenshots or logs into the repo.
- **Retry transient failures once.** On a network/timeout error mid-flow, retry
  the failed step once before reporting. Don't retry definite errors (missing
  element, AX-tree mismatch, build failure) — surface those immediately.

## Reporting contract

When you finish a flow test, the message back to the human must include:

- **Build configuration** (Debug unless Release was asked for).
- **Screenshots:** `/tmp/` paths + a one-line description of each.
- **Log capture path** (if any) + a brief excerpt of anything noteworthy
  (`Log.error` / `Log.warning`).
- A one-line characterization of each meaningful state encountered.
- **What broke** — anything broken, anything off in the accessibility tree, any
  missing identifier — plus an explicit list of what needs **device-only / manual
  verification** (CallKit, real audio, routing).

## Testing follow-through

- **Coverage gap** (do): a flow test reveals an area with *no* existing test
  coverage — propose and write a test before declaring the area verified.
- **Regression backfill** (don't, unprompted): a flow test reveals a bug in
  behavior that *should already* be tested — fix the behavior, report the gap, and
  let the human decide whether to convert it into a test.

## Shell fallback

When the MCP isn't connected, or for one-off human verification:

```bash
xcodegen generate   # required after a fresh clone or any project.yml change

# Build (Debug default; add -configuration Release for a Release build)
xcodebuild -scheme Conduit -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' build

# Test (iPhone 16 / iOS 18.6 — see the sim pin in CLAUDE.md)
xcodebuild -scheme Conduit -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' test

# Single test (target/suite/method)
xcodebuild -scheme Conduit -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' \
  -only-testing:ConduitTests/SomeSuite/someTest test
```

A clean build shows **zero** Swift warnings (the strict baseline + CI gate hold
the count at 0):

```bash
xcodebuild ... build 2>&1 | grep -E "^\/.+\.swift:\d+:\d+: warning:"
```
