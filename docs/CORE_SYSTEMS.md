# Core Systems

The shared, app-agnostic infrastructure under `Conduit/Core/`. Built so far: the
foundation (M0), the call state machine (M1), the Daily transport (M2), the
CallKit + audio-session seam (M3), and the Keychain + Contacts-mirror reals
(WS-4). What remains is the feature UI (WS-5) and the native LiveKit transport
(WS-6). Every external boundary already has a protocol seam and an in-app fake,
so everything above them is testable at sim speed today.

## The testability spine: protocol seams + fakes

Every external boundary is a protocol with a real implementation (some pending)
and an in-app fake. **No concrete CallKit / Pipecat / Keychain / Contacts type is
referenced outside its own service folder** — ViewModels and the coordinator see
only protocols. Fakes live in the **app target** (not the test target) so the unit
suite, SwiftUI previews, and the future CallKit-free debug path all reuse them.

| Seam | Protocol (`Core/Services/…`) | Fake (present) | Real (status) |
|---|---|---|---|
| CallKit | `CallProviding` + `CallProviderDelegate` + `AudioSessionActivating` (`CallKit/`) | `FakeCallProvider` / `FakeAudioSession` | `SystemCallProvider` (built, M3) |
| Transport | `Transport` (`Transport/`) | `FakeTransport` | `PipecatDailyTransport` (built, M2); `LiveKitTransport` — WS-6 |
| Keychain | `KeychainStoring` (`Keychain/`) | `InMemoryKeychain` | `KeychainService` (built, WS-4) |
| Contacts | `ContactsMirroring` (`Contacts/`) | `FakeContactsMirror` | `ContactsService` (built, WS-4) |
| Persistence | `AgentRepository` (`Persistence/`) | — | `SwiftDataAgentRepository` (built) |

The `Transport` event surface is Conduit's own vocabulary (`TransportEvent`:
`connecting` / `connected` / `reconnecting` / `disconnected(reason:)` /
`botStartedSpeaking` / … / `remoteAudioLevel` / `error`), deliberately **not**
Daily/LiveKit/RTVI types, so a second transport drops in behind the same protocol.

`PipecatDailyTransport` (`Transport/`) wraps `PipecatClient` + the Daily transport
and maps RTVI/Daily callbacks to `TransportEvent`s. `.connected` is emitted only on
RTVI `.ready`/`onBotReady` (transport **and** bot ready), never raw connectivity. It
joins with the mic disabled — capture enables only via `setMicEnabled` — so the mic
is never hot before CallKit activation. **Daily audio is device-only:** its WebRTC
voice-processing audio unit aborts in the iOS Simulator (see `bugs.md`), so the sim
verifies pairing/negotiation only; real connect + downlink is verified on device
(confirmed M2: the `live` agent greets on connect via RTVI `client-ready`).

## AppEnvironment (composition root)

`Core/Services/AppEnvironment.swift` — a `@MainActor @Observable` container that
owns the SwiftData `ModelContainer`, the protocol-typed services, a
`transportFactory: (TransportKind) -> Transport`, and the app-wide
`CallSessionCoordinator`. `inMemory()` wires the fakes + an in-memory store
(previews, tests). `live()` (what `ConduitApp` runs on) wires the real services —
`KeychainService`, `ContactsService`, a persistent SwiftData store, and
`SpeechSpokenStateAnnouncer`. CallKit (`SystemCallProvider`) and the Daily
transport can't run in the simulator, so `live()` falls back to the call/transport
fakes there via `#if targetEnvironment(simulator)` while keeping
Keychain/Contacts/persistence real on both — so a real call is device-only, but
add-agent / token / mirror / persistence work in the sim. `ConduitApp` injects the
environment via `.environment(_:)` + `.modelContainer(_:)`.

## Models & persistence (SwiftData)

`Core/Models/` holds two `@Model` types:

- **`Agent`** — name, `detail` (`description` is reserved on reference types),
  avatar, the synthetic email handle, transport kind, connection URL, optional
  pairing endpoint, the mirror toggle, an optional `contactIdentifier`, and a
  `keychainTokenRef`. **The token is never stored here** — only a deterministic
  ref into the Keychain (`agent.token.<uuid>`).
- **`CallLogEntry`** — direction, start, duration, outcome (`completed` / `failed`
  / `declined` / `noAnswer` / `canceled`), transport kind.

`Agent` 1—* `CallLogEntry` with `@Relationship(.cascade)`: deleting an agent wipes
its log; deleting a single entry nullifies its `agent` and removes only that row
(history removed, agent kept). The **synthetic handle** (`Agent+Handle.swift`) is
minted once from the immutable `id` as `<slug>-<id8>.agent.conduit.invalid` — an
email-type handle on the reserved `.invalid` TLD, so Siri/CallKit read the display
name rather than the raw ID. `AgentRepository` (main-actor) wraps `ModelContext`
for mutations and non-view fetches; list screens use `@Query` directly.

## Keychain & the contacts mirror (WS-4)

`KeychainService` (`Keychain/`) stores each agent's connection token as a
generic-password item keyed by `(service, KeychainTokenRef.account)`, with
`kSecAttrAccessibleAfterFirstUnlock` so a call can connect from the lock screen /
CarPlay after the first post-boot unlock. `setToken` is update-or-add (no
duplicate items on re-save); `token` returns `nil` (not an error) when absent;
`delete` treats "not found" as success. **The token never leaves the Keychain** —
SwiftData persists only the `KeychainTokenRef`. The round-trip is unit-tested on
the simulator under a per-test service namespace.

`ContactsService` (`Contacts/`) is the **optional, per-agent** system-contact
mirror over `CNContactStore`. When enabled it writes a contact whose email field
holds the agent's synthetic `.invalid` handle, so iOS matches an outgoing call to
it and the native call UI shows the agent's **name + photo** instead of the raw
handle. Lifecycle edges are owned with the caller (WS-5): permission is requested
only when the toggle is flipped on, `upsertMirror` runs on add/edit,
`removeMirror` on delete/toggle-off. `removeMirror` gets only the agent id, so it
locates the contact by the **stable `id8` suffix** of the synthetic email (minted
once at creation, unchanged on rename) — that suffix-matches-minted-email
invariant is the key unit test. The `CNContactStore` round-trip needs Contacts
permission and writes the address book, so it's device/manual-verified; the pure
mapping (`configure`, `emailSuffix`) is unit-tested. *Known caveat:* an
app-created contact can linger after the app is uninstalled (iOS gives no
uninstall hook).

## Call state machine — `CallSessionCoordinator`

`Core/Services/Call/CallSessionCoordinator.swift` — a `@MainActor @Observable`
type that is the single source of truth for a call and the orchestration point
between the CallKit and transport seams. It lives in `Core/Services/Call/` (not in
`Features/InCall/`) because it is an app-wide service owned by `AppEnvironment` and
consumed by multiple features (Recents redial, Contacts/AgentDetail call, the
InCall projection). It conforms to `CallProviderDelegate`.

`CallState` (`Core/Models/CallState.swift`, pure/`Equatable`):

```
idle → dialing → connecting → connected(since:) → reconnecting(attempt:) ⇄ connected
                                                 ↘ ended(CallOutcome) | failed(CallFailureReason)
```

Key behaviors:

- **Audio-session ownership invariant.** `transport.attachAudioSession()` is
  reachable from exactly one place — `activate(_:)`, entered only via the CallKit
  `providerDidActivate` callback — and the mic is never enabled before activation.
  On activation the coordinator forces speaker only when no external (car/Bluetooth)
  route is present, so it never yanks audio off a connected car.
- **`.connected` requires both** transport-ready and bot-ready (the transport
  emits `.connected` only when both hold), so the native timer / "Connected"
  announcement never fires before the agent can actually hear the user.
- **Idempotent terminal transitions.** `fail` / `endRemote` / `finishEnded` all
  guard on `state.isTerminal`, so the real CallKit "end" round-trip
  (`endCall` → `providerPerformEndCall`) cannot double-write the call log.
- **Failure distinctions.** `authFailed` → `failed(.badToken)` (red in Recents);
  a never-connected drop → `failed(.transportError)`; a mid-call drop → reconnect.

## Reconnection + spoken state

A dropped media connection while CallKit still believes the call is up is the
defining driving problem. Reconnection is **event-driven**: each
`.disconnected(.networkDropped)` is one attempt; `ReconnectionPolicy`
(`Core/Models/`, pure: `base * 2^(n-1)` capped, default 6 attempts / 1 s / 30 s)
gates the budget; a `.connected` recovers and resets; exhaustion →
`failed(.lostConnection)`. A transport that self-heals may emit `.reconnecting`
(display-only — it does not count against the budget). *No jitter:* this is a
single client calling one agent, so there is no thundering-herd to spread.

`SpokenStateAnnouncing` (`Core/Services/Audio/`) speaks connection state in a
deliberately robotic built-in voice, distinct from the agent's, since the agent is
exactly what's unreachable: "Connecting"/"Retrying connection" repeat on a ~7 s
cadence, "Connected"/"Disconnected" once. The real `SpeechSpokenStateAnnouncer`
uses `AVSpeechSynthesizer`; it must mix with (never deactivate) the
CallKit-owned session — that ducking/session wiring is finalized in WS-3.

## Audio-session / CallKit integration (built, M3)

`SystemCallProvider` (`CallKit/`) wraps `CXProvider` + `CXCallController` and
bridges the `CXProviderDelegate` callbacks onto `CallProviderDelegate`. The
`CXProviderDelegate` methods are `nonisolated` and hop onto the main actor via
`MainActor.assumeIsolated` (the delegate queue is `nil` → the main queue).
`SystemAudioSession` (`AudioSessionActivating`) pre-configures the session
(`.playAndRecord` / `.voiceChat`, Bluetooth + A2DP + duck) **without activating
it** — CallKit activates, the coordinator attaches media in `providerDidActivate`,
and on activation forces speaker only when no external (car/Bluetooth) route is
present. The seam was device-verified end-to-end in M3: connect + two-way audio +
Dynamic Island pill + lock-screen call screen + clean teardown.

On an outgoing call, `SystemCallProvider` reports a `CXCallUpdate` with
`localizedCallerName` set to the agent's name, so the call/lock screen shows the
name rather than the raw synthetic email handle. The **photo** (and
Contacts/Siri matching) comes from the optional contact mirror above; the name
shows with or without it. Device-only (CallKit doesn't run in the sim);
interruption / incoming-PSTN handling is the remaining device-flagged work.

## Shared utilities

- **`Log`** (`Core/Utilities/Log.swift`) — categorized os.log facade. See
  [CONVENTIONS § Logging](./CONVENTIONS.md#logging).
- **`AccessibilityID`** (`Core/Utilities/AccessibilityID.swift`) — base namespace
  for accessibility identifiers. See
  [CONVENTIONS § Accessibility](./CONVENTIONS.md#accessibility--the-accessibilityid-convention).
