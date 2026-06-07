# Core Systems

The shared, app-agnostic infrastructure under `Conduit/Core/`. The foundation
(M0) and the call state machine (M1) are built; the **real** CallKit/transport/
Keychain/Contacts implementations are still to land (WS-2 Daily transport, WS-3
CallKit + audio session, WS-4 Keychain/Contacts) — each already has a protocol
seam and an in-app fake, so everything above them is testable today.

## The testability spine: protocol seams + fakes

Every external boundary is a protocol with a real implementation (some pending)
and an in-app fake. **No concrete CallKit / Pipecat / Keychain / Contacts type is
referenced outside its own service folder** — ViewModels and the coordinator see
only protocols. Fakes live in the **app target** (not the test target) so the unit
suite, SwiftUI previews, and the future CallKit-free debug path all reuse them.

| Seam | Protocol (`Core/Services/…`) | Fake (present) | Real (status) |
|---|---|---|---|
| CallKit | `CallProviding` + `CallProviderDelegate` + `AudioSessionActivating` (`CallKit/`) | `FakeCallProvider` / `FakeAudioSession` | `SystemCallProvider` — WS-3 |
| Transport | `Transport` (`Transport/`) | `FakeTransport` | `DailyTransport` — WS-2; `LiveKitTransport` — WS-6 |
| Keychain | `KeychainStoring` (`Keychain/`) | `InMemoryKeychain` | `KeychainService` — WS-4 |
| Contacts | `ContactsMirroring` (`Contacts/`) | `FakeContactsMirror` | `ContactsService` — WS-4 |
| Persistence | `AgentRepository` (`Persistence/`) | — | `SwiftDataAgentRepository` (built) |

The `Transport` event surface is Conduit's own vocabulary (`TransportEvent`:
`connecting` / `connected` / `reconnecting` / `disconnected(reason:)` /
`botStartedSpeaking` / … / `remoteAudioLevel` / `error`), deliberately **not**
Daily/LiveKit/RTVI types, so a second transport drops in behind the same protocol.

## AppEnvironment (composition root)

`Core/Services/AppEnvironment.swift` — a `@MainActor @Observable` container that
owns the SwiftData `ModelContainer`, the protocol-typed services, a
`transportFactory: (TransportKind) -> Transport`, and the app-wide
`CallSessionCoordinator`. `inMemory()` wires the fakes + an in-memory store
(previews, tests, and today's running shell). A `live()` factory is introduced as
the real services land. `ConduitApp` injects it via `.environment(_:)` +
`.modelContainer(_:)`.

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

## Audio-session / CallKit integration (pending real impl)

The seam is modeled (`AudioSessionActivating`, the `providerDidActivate` /
`providerDidDeactivate` callbacks, the route decision), and the ownership
invariant is enforced and unit-tested against fakes. The real `CXProvider` /
`CXCallController` wiring, the live `AVAudioSession` activation handshake, route
defaults on device, and interruption/incoming-PSTN handling land in WS-3 and are
device-only (Layer 2–3).

## Shared utilities

- **`Log`** (`Core/Utilities/Log.swift`) — categorized os.log facade. See
  [CONVENTIONS § Logging](./CONVENTIONS.md#logging).
- **`AccessibilityID`** (`Core/Utilities/AccessibilityID.swift`) — base namespace
  for accessibility identifiers. See
  [CONVENTIONS § Accessibility](./CONVENTIONS.md#accessibility--the-accessibilityid-convention).
