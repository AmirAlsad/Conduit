# Repository Guidelines

## Project Structure & Module Organization
- `Conduit/`: main iOS app code.
  - `App/`: app entry point and global state.
  - `Core/`: shared models, services, and utilities (e.g. `Core/Utilities/Log.swift`).
  - `Features/`: feature modules (Views, ViewModels, Models, Services, Coordinators).
  - `Shared/`: reusable components and navigation helpers.
  - `Resources/` and `Assets.xcassets`: fonts, JSON/audio, and xcassets.
- `Config/`: shared build settings (`Base.xcconfig`) and per-developer local overrides.
- `ConduitTests/` and `ConduitUITests/`: test targets.
- `docs/`: architecture, conventions, and feature guides (see `docs/README.md` for load order).
- `project.yml`: XcodeGen project definition; `Conduit.xcodeproj` is generated from it and gitignored.

## Build, Test, and Development Commands
- After cloning, generate the project before opening or building:
  - `xcodegen generate` (reads `project.yml`). The `.xcodeproj` is not committed.
- Open `Conduit.xcodeproj` in Xcode and run the `Conduit` scheme.
- For agent-driven builds/tests/runs: prefer XcodeBuildMCP tools (`mcp__xcodebuildmcp__build_sim`, `mcp__xcodebuildmcp__test_sim`, `mcp__xcodebuildmcp__build_run_sim`). The MCP server is project-scoped via `.mcp.json`, and the `xcodebuildmcp` skill at `.claude/skills/xcodebuildmcp/` documents which tool to reach for in each situation.
- Regenerate the project after any change to `project.yml` or after adding/removing source files:
  - `xcodegen generate`
- Shell fallback (humans, or agents without MCP):
  - `xcodebuild -scheme Conduit -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' build`
  - `xcodebuild -scheme Conduit -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' test`
- Prefer an exact destination from `xcodebuild -showdestinations -scheme Conduit`. A bare `name=iPhone 16` can resolve to `OS=latest` (the iOS 26 sim, which has a broken accessibility subsystem for XCUITests); always pin `platform=iOS Simulator,name=iPhone 16,OS=18.6`.

## Configuration & Secrets
- Local config: copy `Config/local.xcconfig.template` to `Config/local.xcconfig` and fill in your `DEVELOPMENT_TEAM` and `APP_BUNDLE_IDENTIFIER`. This is the single canonical per-developer override file.
- Keep `Config/local.xcconfig` uncommitted (gitignored). Test/UITest bundle ids derive from `APP_BUNDLE_IDENTIFIER` automatically.
- The committed `Config/Base.xcconfig` is the least-privileged baseline so anyone can clone and build with zero edits. Conduit currently needs no paid capability or entitlements (CallKit, the VoIP background mode, and the microphone are declared in `Conduit/Info.plist`).
- Do not commit secrets, developer-specific identifiers, the generated `Conduit.xcodeproj`, or any per-agent connection tokens. Agent connection credentials are user-supplied at runtime and stored in the Keychain — never in source.

## Coding Style & Naming Conventions
- Follow `docs/CONVENTIONS.md` for SwiftUI patterns (`@StateObject`, `@EnvironmentObject`, `@Observable`).
- Keep UI-facing code on `@MainActor`; prefer async/await over callbacks.
- Naming: `*View`/`*Screen`/`*Card`, `*ViewModel`, `*Service`/`*Manager`, `*Coordinator`, `*Sheet`.
- Files map 1:1 with primary types; extensions use `Type+Category.swift`.
- Use the `Log` utility (pure `os.log`) with categories for logging.
- Every interactive element gets a stable `<Feature>_<Element>` accessibility identifier.

## Testing Guidelines
- Unit tests in `ConduitTests/`, UI tests in `ConduitUITests/`.
- The simulator cannot exercise CallKit or capture the mic over WebRTC: logic and state machines unit-test in the sim; the transport/CallKit boundary and audio routing are device-only / manual. See CLAUDE.md for the test-scope table.
- Name test methods/functions descriptively and cover both new behavior and regressions.

## Commit & Pull Request Guidelines
- Use concise, sentence-style commit summaries with periods.
- PRs should include a short summary, testing notes, and UI screenshots when applicable; link related docs.
- Update or add relevant documentation for non-trivial code changes (skip for small bug patches or UI-only tweaks).
- Remove dead or deprecated code rather than commenting it out; confirm with the project owner before deleting anything load-bearing.
- If using XcodeBuildMCP, load the `xcodebuildmcp` skill before calling its tools.
