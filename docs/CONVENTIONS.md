# Conventions

House style for Conduit. These rules apply from line one so we never retrofit
them after the codebase grows. (Brand-new app — examples below are illustrative;
not all referenced files exist yet.)

## Code Style

### SwiftUI Patterns

- Prefer the **`@Observable`** macro for new observable types (view models,
  stores) — not `ObservableObject` / `@Published`.
- **`@State`** owns a view's local state and its `@Observable` view model:
  ```swift
  @State private var viewModel = InCallViewModel()
  ```
- UI-facing types are **`@MainActor`**. Mark view models and anything that mutates
  UI-observed state on the main actor; let the compiler enforce hops.
- **`async`/`await` over callbacks.** All async work uses Swift concurrency — no
  completion handlers, no Combine for new code:
  ```swift
  func connect() async throws
  ```
  This matters most at the transport/CallKit boundary, where the audio-session
  handshake and reconnection logic read far more clearly as structured async.
- Extract complex views into their own files; keep `body` shallow.

## Naming Conventions

### Types

| Type | Pattern | Example |
|------|---------|---------|
| Views | `*View` | `RecentsView`, `InCallView`, `AgentDetailView` |
| ViewModels | `*ViewModel` | `InCallViewModel`, `ContactsViewModel` |
| Services / Managers | `*Service`, `*Manager` | `KeychainService`, `ContactSyncService` |
| Coordinators | `*Coordinator` | none today (the call state machine is `CallEngine`, in the `ConduitCallEngine` package) |
| Sheets | `*Sheet` | `AddEditAgentSheet` |

### Files

- One type per file (exception: a handful of small, tightly-related types).
- File name matches the primary type.
- Extensions use **`Type+Category.swift`** — e.g. `Agent+CallTarget.swift`,
  `AudioRouteKind+Display.swift`.

## File Organization

```
Features/<Feature>/
├── Views/
│   ├── <Feature>View.swift
│   ├── Components/        # feature-specific subviews
│   └── Sheets/           # modal sheets
├── ViewModels/
│   └── <Feature>ViewModel.swift
├── Models/               # optional, feature-specific
├── Services/             # optional, feature-specific
├── Coordinators/         # optional, complex flows
└── AccessibilityID+<Feature>.swift
```

Shared, app-agnostic infrastructure lives in `Core/` (e.g. `Core/Utilities/`
holds `Log.swift` and the `AccessibilityID` base namespace). Reusable UI and
navigation live in `Shared/`.

## Accessibility — the `AccessibilityID` convention

Stable accessibility identifiers are the backbone of reliable XCUITest **and**
agent-driven UI automation: tools query by identifier, never by raw coordinates
or label text. This matters doubly here — the in-call screen is the surface
automation drives during Layer-2 device tests.

**The rules:**

1. **One `AccessibilityID+<Feature>.swift` per feature.** Each extends the shared
   `AccessibilityID` namespace (`Core/Utilities/AccessibilityID.swift`) with a
   nested `enum <Feature>`. Don't amend the umbrella enum — register a feature by
   creating its extension file.
2. **`<Feature>_<Element>` constants**, PascalCase. The feature prefix keeps every
   identifier collision-free and greppable from test page objects.
3. **`static func` for indexed / parameterized ids** — list rows, enum-keyed
   segments, anything dynamic.
4. **Every interactive element gets one.** Buttons, `TextField`/`SecureField`,
   `Toggle`, `Slider`, `Picker`, `NavigationLink`, `.onTapGesture`, and custom
   `*Button`/`*Card` views all carry `.accessibilityIdentifier(...)` from the
   namespace — never an inline string literal.
5. **Automation never uses raw coordinates.** If an element lacks an identifier,
   add one rather than tapping by point. Flag missing identifiers during review.

```swift
// Core/Utilities/AccessibilityID.swift
enum AccessibilityID {}

// Features/Recents/AccessibilityID+Recents.swift
extension AccessibilityID {
    enum Recents {
        static let screen = "Recents_Screen"
        static let clearAllButton = "Recents_ClearAllButton"
        static func callRow(_ index: Int) -> String { "Recents_CallRow_\(index)" }
    }
}

// usage
.accessibilityIdentifier(AccessibilityID.Recents.clearAllButton)
```

## Build & Per-Developer Override Model

The committed repo builds for the simulator with no local setup; everything that
differs per developer (team id, bundle id) lives in a gitignored override file.

### `Config/Base.xcconfig` — committed, least-privileged defaults

Holds shared identity/version build settings and ends with a conditional include
of the per-developer file. The committed defaults are deliberately the lowest-privilege
path, so a fresh clone builds for the simulator with zero edits (device builds need
a team id and the capabilities below):

```
PRODUCT_NAME = Conduit
APP_BUNDLE_IDENTIFIER = com.conduit.Conduit   // neutral committed default
MARKETING_VERSION = 1.0
CURRENT_PROJECT_VERSION = 1

#include? "local.xcconfig"   // the `?` makes it optional — absence is not an error
```

`project.yml` wires this in via `configFiles: { Debug: Config/Base.xcconfig,
Release: Config/Base.xcconfig }` on each target, and the app target sets
`PRODUCT_BUNDLE_IDENTIFIER = $(APP_BUNDLE_IDENTIFIER)`; the test/UITest targets
derive `.tests` / `.uitests` from it automatically.

### `Config/local.xcconfig` — gitignored, per-developer

Each developer creates this from the committed template and fills in their own
signing values. It is the **single canonical place** for per-developer overrides
(there is intentionally no `project.local.yml`):

```
DEVELOPMENT_TEAM = YOUR_TEAM_ID_HERE
APP_BUNDLE_IDENTIFIER = com.yourname.Conduit
```

**Setup:** copy `Config/local.xcconfig.template` → `Config/local.xcconfig` and
fill in your `DEVELOPMENT_TEAM` and `APP_BUNDLE_IDENTIFIER`. `local.xcconfig` is
gitignored; never commit it.

### Entitlements

The app target declares two entitlements in `project.yml`
(the target's `entitlements` block); XcodeGen writes them to the gitignored
`Conduit/Conduit.entitlements`:

- **`aps-environment`** — VoIP push for inbound calls. The value is
  `$(APS_ENVIRONMENT)`, set per configuration in `project.yml` (Debug `development`,
  Release `production`). Device builds need the Push Notifications capability on
  the App ID (a paid Apple Developer account); the simulator ignores it.
- **`com.apple.developer.siri`** — SiriKit calling domain. A standard capability
  that automatic signing adds to the App ID.

CallKit, the `voip` and `audio` background modes, the microphone, and the local
network prompt are `Info.plist` entries and need no entitlement. To add another
entitlement, add it to that block and re-run
`xcodegen generate`. Per-developer signing values (team id, bundle id) stay in
`Config/local.xcconfig`.

### Regenerating the project

The `.xcodeproj` is generated by XcodeGen and gitignored. After any change to
`project.yml` (or after adding/removing source files), run **`xcodegen
generate`**. A fresh clone must run it before the first build, and **CI runs it
before every build** (see `.github/workflows/tests.yml`).

`project.yml` consumes the `ConduitCallEngine` package by version
(`minorVersion: "0.2.0"`, 0.2.x only) from GitHub, so a fresh clone needs no
sibling checkout. The tracked root `Package.resolved` pins
every package; `xcodegen generate` copies it into the generated project (the
`postGenCommand`), because the gitignored `.xcodeproj` would otherwise resolve to
newer, unverified SDKs. Change a pin deliberately, commit the `Package.resolved`
diff, and re-check the built app with `scripts/check-bundle.sh`.

## Logging

All logging goes through the `Log` utility (`Core/Utilities/Log.swift`), built on
Apple's unified logging (`os.Logger`). **No print, no third-party, no analytics,
no crash reporting** — per the project decisions (no backend, no Firebase, no
analytics).

### Call sites

```swift
Log.<level>(.<category>, "…")

Log.info(.transport, "Joined room")
Log.warning(.audio, "Route changed mid-call")
Log.error(.callkit, "Provider failed to report call: \(error)")
```

### Levels

- `Log.debug()` — verbose checkpoints (DEBUG builds only).
- `Log.info()` — key checkpoints (DEBUG builds only).
- `Log.warning()` — recoverable issues (always emitted).
- `Log.error()` — failures (always emitted).

`debug` / `info` are compiled out of release builds, so verbose checkpoints stay
free in production; `warning` / `error` always log.

### Categories

Categories are an `enum` with emoji-prefixed labels for fast console scanning:
`.app`, `.call`, `.callkit`, `.transport`, `.webrtc`, `.audio`, `.contacts`,
`.agent`, `.network`, `.ui`. Add a new case to `LogCategory` when a genuinely new
domain appears. The `ConduitCallEngine` package has its own package-internal `Log`
with the same call shape, labels and subsystem (the host's bundle id) for the
categories it uses (`.call`, `.callkit`, `.transport`, `.audio`, `.network`), so
engine lines appear alongside the app's in Console.
The package routes its log through `CallEngineLog`: by default straight to unified
logging, or to a `handler` the host installs. The app installs one in DEBUG builds
only (`CallTrace.captureEngineLog()`), which writes each event into the call trace
and still forwards it to Console; Release builds keep the package's default, where
debug and info lines are not delivered. The package removes credentials from every
message before the handler sees it.

### Privacy

Never log raw PII (tokens, emails, handles). Use the redaction helpers on `Log`
(`Log.redact(_:)`, `Log.redactEmail(_:)`) for any sensitive value — the agent's
token lives in the Keychain and must never appear in logs.

## Comments

- Document non-obvious logic inline — especially anything around the
  CallKit↔audio-session timing, where the *why* is far from obvious from the code.
- Use `// MARK: -` for section organization.
- Avoid redundant comments that merely restate the code.
