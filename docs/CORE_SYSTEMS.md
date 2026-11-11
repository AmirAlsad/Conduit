# Core Systems

The shared infrastructure under `Conduit/Core/` and the engine package it sits on.
Built so far: the foundation (M0), the call state machine (M1), the Daily transport
(M2), the CallKit + audio-session seam (M3), the Keychain real + persistence (WS-4),
and the native LiveKit transport (M6). Every external boundary has a protocol seam
and a fake, so everything above them is testable at sim speed.

## Where the code lives

The call engine is the Swift package **`ConduitCallEngine`**, extracted from this
app. Today it is a sibling checkout at `../ConduitCallEngine`, referenced by path in
`project.yml`, so a fresh clone needs it next to this repo; it is meant to be
consumed by version from `github.com/AmirAlsad/ConduitCallEngine` later. The app
links four of its products:

| Product | Holds |
|---|---|
| `ConduitCallEngine` | `CallEngine` (the state machine) and its host surface (`CallEngineDelegate`, `CallEngineConfiguration`, `CallTarget`, `ActiveCall`, `IncomingCall`, `CallRecord`); `CallState` and the outcome / failure / direction models; `CallTransport` with `TransportEvent`, `TransportError`, `CallConnection`, `AudioDeviceInfo`, `AudioRouteKind`; the CallKit provider, audio-session and audio-interruption seams; PushKit registration and incoming-push parsing; ring-status receipts; `ReconnectionPolicy`. Imports no transport SDK. |
| `ConduitCallEngineDaily` | `PipecatDailyTransport` |
| `ConduitCallEngineLiveKit` | `LiveKitTransport`, `LiveKitConnectGate`, `LiveKitAudioRouter` |
| `ConduitCallEngineTesting` | `FakeTransport`, `SimulatedCallSystem`, `CallEngine.simulated(...)`; the app links it for the simulator and its tests |

The app keeps `Agent` / `CallLogEntry` and persistence, the Keychain, contacts,
pairing (`PairingClient`), the SmallWebRTC adapter, the spoken-state announcer and
ringback, the missed-call notification, Siri, token registration with each agent's
server, and all UI. The glue between the two is `Core/Services/AgentCalls/`:
`Agent+CallTarget` builds a `CallTarget` from an agent, and `AgentCallHost` is the
engine's delegate (see the call state machine below).

The engine's seam protocols (CallKit provider, audio session, interruptions,
PushKit, receipts) are `package`-access: the app never names them, only
`CallEngine`'s public surface. `CallEngine(configuration:)` builds the real
implementations; `CallEngine.simulated(...)` builds the fakes.

## The testability spine: protocol seams + fakes

Every stateful external boundary is a protocol with a real implementation and a
fake. **No concrete CallKit / PushKit / Pipecat / Keychain type is referenced
outside its own service folder** (for the engine's seams, its package) — view
models and the host glue see only protocols and the engine's public surface. The
engine's fakes ship in the package's `ConduitCallEngineTesting` product; the app's
own fakes live in the **app target** (not the test target), so the unit suite,
SwiftUI previews and the simulator path reuse them.

| Seam | Protocol | Fake | Real |
|---|---|---|---|
| CallKit *(package)* | `CallProviding` + `CallProviderDelegate` + `AudioSessionActivating` | `FakeCallProvider` / `FakeAudioSession` | `SystemCallProvider` / `SystemAudioSession` (built, M3) |
| Audio interruptions *(package)* | `AudioInterruptionObserving` + `AudioInterruptionObserverDelegate` | `FakeAudioInterruptionObserver` | `SystemAudioInterruptionObserver` (built; audio device-only) |
| PushKit *(package)* | `VoIPPushRegistering` | `FakeVoIPPushRegistry` | `SystemVoIPPushRegistry` |
| Ring-status receipts *(package)* | `RingStatusReporting` | `FakeRingStatusReporter` | `RingStatusReporter` |
| Transport | `CallTransport` (package, public) | `FakeTransport` (package) | `PipecatDailyTransport` (package, M2); `LiveKitTransport` (package, M6); `PipecatSmallWebRTCTransport` (app, `Core/Services/Transport/`, M9) |
| Keychain | `KeychainStoring` (`Keychain/`) | `InMemoryKeychain` | `KeychainService` (built, WS-4) |
| Contacts sync | `ContactSyncing` (`Contacts/`) | `FakeContactSync` | `ContactSyncService` (built) |
| Persistence | `AgentRepository` (`Persistence/`) | — | `SwiftDataAgentRepository` (built) |
| Spoken state | `SpokenStateAnnouncing` (`Audio/`) | `FakeSpokenStateAnnouncer` | `SpeechSpokenStateAnnouncer` (built) |
| Missed-call notification | `MissedCallNotifying` (`Push/`) | test double in `ConduitTests/Support/` | `MissedCallNotifier` (built) |
| Siri donation | `CallInteractionDonating` (`Siri/`) | `FakeCallInteractionDonor` | `CallInteractionDonor` (built) |
| Inbound registration | `InboundRegistering` (`Push/`) | `FakeInboundRegistrar` | `AgentCallHost` (built) |

`SimulatedCallSystem` stands in for CallKit, PushKit, the interruption source and
ring-status receipts together. A host test (or the simulator) drives what the
system would do through it — deliver a push or a VoIP token, answer or end a call
from the system UI, reset the provider, deliver a transport event — and reads what
the engine reported (`reportedIncomingCalls`, `updatedCalls`, `startedCallIDs`,
`ringReceipts`). `CallEngine.simulated(configuration:system:)` builds an engine
over it; `AppEnvironment.live()` uses that in the simulator and `inMemory()`
everywhere.

*Adding* an agent to Contacts has no seam — it goes through the system
`CNContactViewController` (see below), so there is no store round-trip to abstract.
Only *updating* a linked contact (sync-on-save) touches `CNContactStore`, behind
the `ContactSyncing` seam above.

The `CallTransport` event surface is Conduit's own vocabulary (`TransportEvent`:
`connecting` / `connected` / `reconnecting` / `disconnected(reason:)` /
`botStartedSpeaking` / … / `remoteAudioLevel` / `error`), deliberately **not**
Daily/LiveKit/RTVI types, so a further transport drops in behind the same protocol.

Transports never pair: `connect(_:)` takes an already-resolved `CallConnection`
(room/offer URL + optional token). The engine is handed a `CallTarget` (id,
display name, handle, `makeTransport`, `connect`); it calls `makeTransport()` and
subscribes **first**, then awaits `target.connect()` for the credentials, then
joins — so a CallKit activation that lands mid-fetch still reaches
`attachAudioSession()`. `target.connect()` re-runs for every reconnect attempt.
For agents the target comes from `Agent+CallTarget`
(`Core/Services/AgentCalls/`): pairing via `PairingClient` (re-paired per attempt),
the direct room + Keychain token, or inline push credentials (the same room every
attempt); the agent's configuration is captured when the target is made.
`PairingError.unauthorized` maps to `TransportError.authenticationFailed`
(→ `.badToken`); other pairing failures to `.connectionFailed` (→ `.transportError`);
a direct agent with no token throws `.authenticationFailed`. Ending the call while
it is dialing, while a resolve is in flight, or during a reconnect attempt leaves
that attempt inert (no join, no return to `.reconnecting`).

`PipecatDailyTransport` (package product `ConduitCallEngineDaily`) wraps
`PipecatClient` + the Daily transport and maps RTVI/Daily callbacks to
`TransportEvent`s. `.connected` is emitted only on RTVI `.ready`/`onBotReady`
(transport **and** bot ready), never raw connectivity. It joins with the mic
disabled — capture enables only via `setMicEnabled` — so the mic is never hot
before CallKit activation. **Daily audio is device-only:** its WebRTC
voice-processing audio unit aborts in the iOS Simulator (see `bugs.md`), so the sim
verifies pairing/negotiation only; real connect + downlink is verified on device
(confirmed M2: the `live` agent greets on connect via RTVI `client-ready`).

`LiveKitTransport` (package product `ConduitCallEngineLiveKit`, M6) is the native
second transport over `livekit/client-sdk-swift`, behind the same protocol. It
re-derives the RTVI-style signals from LiveKit: `.connected` only when the room
**and** the agent (a remote participant) are both ready — the pure, unit-tested
`LiveKitConnectGate` — and bot-speaking from `didUpdateSpeakingParticipants`. The
pairing contract is transport-neutral (for a LiveKit agent the response's
`room_url` is LiveKit's `wss://` URL). The decisive difference from Daily is
**manual audio**: at init it sets
`AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = false`, and it
gates LiveKit's audio engine on CallKit via the `attachAudioSession`/`detachAudioSession`
seam (`setEngineAvailability(.default/.none)` in `providerDidActivate`/`Deactivate`).
Activation and `connect()` are **unordered edges**: the transport tracks
`isSessionAttached`, and `connect()` asserts the *current* attach state rather than
unconditionally resetting to `.none` — an unconditional reset stomped a mid-fetch
activation and killed the mic on cold-launch first calls (`bugs.md`,
`potential_skills/callkit.md`).
Because CallKit then truly owns the `AVAudioSession`, **the native call-screen route
button moves the audio** (Daily can't — see `bugs.md`), and the in-app picker routes
through `AVAudioSession` directly (`LiveKitAudioRouter`) instead of the SDK. Like
Daily, it's **device-only** (WebRTC audio aborts in the sim), so `live()` uses
`FakeTransport` in the simulator; the only sim-tested logic is `LiveKitConnectGate`.

`PipecatSmallWebRTCTransport` (app, `Core/Services/Transport/`, M9) is the
zero-cloud third transport: peer-to-peer WebRTC straight to the user's own Pipecat
server (LAN / self-hosted — UDP media, so never behind an HTTP-only host). It is
host code conforming to the package's `CallTransport`, mirroring the Daily adapter
(`PipecatClient` + the package's `SmallWebRTCTransport`); pairing returns the
engine's **offer URL** + a short-lived bearer as `room_url`/`token`, and the SDK
POSTs the SDP offer / PATCHes trickle-ICE to that URL with the bearer attached.
Audio follows the **Daily pattern** (SDK owns the session config; joins
mic-disabled; attach/detach no-ops). **Load-bearing:** the stock package's
stasel/WebRTC collides with Daily's embedded WebRTC (un-prefixed `RTC*` classes
duplicated → Daily calls crash), so `project.yml` pins our fork built against
`LiveKitWebRTC` — and the fork stays an **app-only** dependency, never one of the
engine package's. See `bugs.md` and ROADMAP M9 before bumping any transport SDK;
`scripts/check-bundle.sh <Conduit.app>` is the static check on the built app.

All three adapters send the engine's **`end-call` signal** in `disconnect()` — a
deliberate hangup ends the bot at once instead of burning its human-absent grace
window (Daily and SmallWebRTC: `sendClientMessage("end-call")` over the Pipecat
channel; LiveKit: the RTVI envelope published on the data channel, because
Pipecat's LiveKit input path doesn't deliver client RTVI messages — see
`bugs.md`). Reconnects never call `disconnect()`, so a genuine drop still gets
the grace window (smallwebrtc's engine side ends immediately on peer drop
instead — the iOS SDK can't reconnect in place; a retry re-pairs to a fresh bot).

## AppEnvironment (composition root)

`Core/Services/AppEnvironment.swift` — a `@MainActor @Observable` container that
owns the SwiftData `ModelContainer`, the protocol-typed services, a
`transportFactory: (TransportKind) -> CallTransport`, the app-wide
`CallEngine`, and its delegate `AgentCallHost`. UI places calls through
`AppEnvironment.placeCall(_ agent:)` and reads the live call's agent (name, avatar,
color) from `activeCallAgent`, looked up by `callEngine.activeCall?.targetID`.
`inMemory()` wires the fakes + an in-memory store (previews, tests): a
`CallEngine.simulated` engine over a `SimulatedCallSystem`, `FakeTransport`s, an
`InMemoryKeychain`. `live()` (what `ConduitApp` runs on) wires the real services —
`KeychainService`, a persistent SwiftData store, `SpeechSpokenStateAnnouncer`, and
on a device the real `CallEngine(configuration:)` (CallKit, PushKit) with
`PipecatDailyTransport` / `LiveKitTransport` / `PipecatSmallWebRTCTransport`.
CallKit, PushKit and WebRTC audio can't run in the simulator, so there `live()`
falls back to `CallEngine.simulated` and `FakeTransport` via
`#if targetEnvironment(simulator)` while keeping Keychain/persistence real on both
— so a real call is device-only, but add-agent / token / persistence work in the
sim. The `AppDelegate` starts the engine's PushKit registration at launch and sets
`inboundRegistrar` to the host. `ConduitApp` injects the environment via
`.environment(_:)` + `.modelContainer(_:)`.

## Models & persistence (SwiftData)

`Core/Models/` holds two `@Model` types:

- **`Agent`** — name, `detail` (`description` is reserved on reference types),
  avatar, a per-agent identity color (`colorTokenRaw`, an `AgentColor` palette
  token — see the in-call surface below), the synthetic email handle, transport
  kind, connection URL, optional pairing endpoint, an optional `contactIdentifier`
  (set once the user adds the agent to Contacts), and a `keychainTokenRef`. **The
  token is never stored here** — only a deterministic ref into the Keychain
  (`agent.token.<uuid>`). `colorTokenRaw` is optional with no default (`nil` ⇒
  name-derived), so the field is an additive, CloudKit-safe migration.
- **`CallLogEntry`** — direction, start, duration, outcome (`completed` / `failed`
  / `declined` / `noAnswer` / `canceled`), transport kind, and an optional persisted
  failure reason. Direction, outcome and failure reason are the engine package's
  `CallDirection` / `CallOutcome` / `CallFailureReason`, stored as raw strings.

`Agent` 1—* `CallLogEntry` with `@Relationship(.cascade)`: deleting an agent wipes
its log; deleting a single entry nullifies its `agent` and removes only that row
(history removed, agent kept). The **synthetic handle** (`Agent+Handle.swift`) is
minted once at creation from the agent's *name* as `<slug>@conduit.invalid` (the
slug is the lowercased ASCII letters and digits joined by `-`, at most 32
characters, or `agent` when empty) and stored, so it is stable across renames. It
is an email-type handle on the reserved `.invalid` TLD, so Siri/CallKit read the
display name rather than the raw handle. Two agents with the same name share a
handle — cosmetic only (the contact photo on the native call screen); calls and
history are keyed by the agent's `id`. `AgentRepository` (main-actor) wraps `ModelContext`
for mutations and non-view fetches; list screens use `@Query` directly.

## Keychain & adding an agent to Contacts

`KeychainService` (`Keychain/`) stores each agent's connection secrets as
generic-password items keyed by `(service, KeychainTokenRef.account)`, with
`kSecAttrAccessibleAfterFirstUnlock` so a call can connect from the lock screen /
CarPlay after the first post-boot unlock. `setToken` is update-or-add (no
duplicate items on re-save); `token` returns `nil` (not an error) when absent;
`delete` treats "not found" as success. **Secrets never leave the Keychain** —
SwiftData persists only the `KeychainTokenRef`. An agent can hold **two**
independent secrets under separate refs both derived from its id — the **pairing
API key** (`agent.token.<id>`, also `Agent.keychainTokenRef`) and the **direct-room
token** (`agent.directToken.<id>`) — so the two connection paths don't share a
field. `Agent+CallTarget` reads whichever the call uses (pairing wins when both
are set). The round-trip is unit-tested on the simulator under a
per-test service namespace.

Adding an agent to Contacts is **optional and permission-free**. From AgentDetail,
"Add to Contacts" presents the system `CNContactViewController(forNewContact:)`
(`NewContactView` in `Shared/Components/`), pre-filled by the pure
`AgentContactBuilder` (`Contacts/`) with the agent's name, photo, and synthetic
`name@conduit.invalid` email (neutral "other" label). The **user** saves it
through system UI, so *adding* never holds Contacts permission. Because the
contact's email matches the call's email-type CXHandle, iOS then shows the agent's
**name + photo** on the call screen, lock screen, and CarPlay in place of the raw
handle. The delegate returns the saved contact's identifier, stored on
`Agent.contactIdentifier` to flip the button to "Added to Contacts".

**Sync on save.** Updating an already-linked contact in place *does* need Contacts
access (the system sheet only creates), so editing a linked agent syncs its name +
photo via `ContactSyncing` → `ContactSyncService` (`CNContactStore.update`), with
`FakeContactSync` for tests. Access is requested **lazily** — only the first time a
*linked* agent is saved (`AddEditAgentViewModel.save`) — so the default stays
permission-free; `NSContactsUsageDescription` covers this one path. Decline → it
stays a snapshot. The tested logic is the builder mapping (`AgentContactTests`) and
the "sync only when linked" decision (`AddEditAgentViewModelTests`). *Known
caveats:* the contact persists after the agent is deleted or the app is uninstalled
(no permission to remove it programmatically,
and iOS gives no uninstall hook); a user who deletes the contact in the Contacts
app leaves a stale `contactIdentifier`.

## Call state machine — `CallEngine`

`CallEngine` (package `ConduitCallEngine`, `Sources/ConduitCallEngine/Call/CallEngine.swift`)
— a `@MainActor @Observable` type that is the single source of truth for a call
and the orchestration point between the CallKit and transport seams. The app owns
one instance through `AppEnvironment`; it is consumed by multiple features
(Recents redial, Contacts/AgentDetail call, the InCall projection). It conforms to
`CallProviderDelegate` and `AudioInterruptionObserverDelegate`.

It knows calls, not agents. The host side is `CallEngineDelegate`
(`Call/CallEngineDelegate.swift` in the package), synchronous and main-actor:
`didChangeStateFrom:to:` fires on every real state change (never for a duplicate
`.connected`), after that transition's other fields are set; `didFinish(CallRecord)`
fires where a call ends (and for a busy ring), carrying a `missedReason` when the
ring never reached the user; `targetForIncomingCall` resolves a push to a
`CallTarget` (nil = unknown, the ring fails); `ringStatusBearerForTarget` supplies
the receipt bearer. Conduit's delegate is `AgentCallHost`
(`Core/Services/AgentCalls/AgentCallHost.swift`): it writes `CallLogEntry` rows
(looking the agent up by target id — none, no row), posts the missed-call
notification for busy / Focus-filtered rings, donates outgoing calls to Siri on
`dialing → connecting`, and speaks the cues from transitions: `→ connecting`
starts the connecting cue (a looped ringback tone, not speech); `→ connected`
stops it and says "Connected"; `→ reconnecting(n)` from `connected`, or with
`n == 1`, says "Disconnected" and starts "Retrying"; `→ ended`/`failed` stops
repeating. A provider reset stops
nothing.

`CallState` (package, `Models/CallState.swift`, pure/`Equatable`):

```
idle → dialing → connecting → connected(since:) → reconnecting(attempt:) ⇄ connected
                                                 ↘ ended(CallOutcome) | failed(CallFailureReason)
incomingRinging → connecting → …   (agent-initiated inbound, after the user answers)
```

`incomingRinging` is the one non-idle state with `isActive == false`: while it
rings, CallKit's system UI is primary, so the app shows no surface until answer.

Key behaviors:

- **Audio-session ownership invariant.** `transport.attachAudioSession()` runs only
  after CallKit's `providerDidActivate` — from `activate(_:)`, or when the transport
  is created after activation already landed (e.g. CallKit activated while dialing
  or before `answer()` ran; it is replayed onto the new transport before the
  credential fetch) — and the mic is never enabled before activation.
- **Hands-free default.** After connect, once the transport's device list is
  populated, the engine selects the speaker through `transport.setAudioDevice` —
  once per call, and only when the list has no Bluetooth or wired route — so it
  never yanks audio off a connected car. It goes through the transport because the
  WebRTC SDK manages the session and reverts an `AVAudioSession` override.
- **`.connected` requires both** transport-ready and bot-ready (the transport
  emits `.connected` only when both hold), so the native timer / "Connected"
  announcement never fires before the agent can actually hear the user.
- **Idempotent terminal transitions.** `fail` / `endRemote` / `finishEnded` all
  guard on `state.isTerminal`, so the real CallKit "end" round-trip
  (`endCall` → `providerPerformEndCall`) cannot double-record the call.
- **Failure distinctions.** `authFailed` → `failed(.badToken)` (red in Recents);
  a never-connected drop → `failed(.transportError)`; a mid-call drop → reconnect.
- **Audio interruptions.** `AudioInterruptionObserving` (real:
  `SystemAudioInterruptionObserver` over `AVAudioSession.interruptionNotification`)
  drives `isInterrupted`: on `.began` the mic pauses (`setMicEnabled(false)`); on
  `.ended(shouldResume:)` it re-applies the correct mic state via `applyMicIfActivated`
  (respecting mute / push-to-talk). The session is never touched — CallKit owns it and
  re-fires `providerDidActivate` after an interruption, so the two are unordered edges
  that both re-apply mic state idempotently. Transient GPS/nav ducking is system-managed
  by `.duckOthers`; this observer covers full takeovers (Siri, a phone call). The live
  audio behavior is device-only; the begin/resume logic is unit-tested via the fake.
- **Inbound (agent-initiated) calls.** A VoIP push (PushKit) → the synchronous
  `handleIncomingPush(_:completion:)`, called straight from the PushKit callback. It
  parses the payload and reports to CallKit **first** (`reportIncomingCall`, which issues
  `reportNewIncomingCall` before returning and completes later), under the push's own
  identity: `display_name` else the configured unknown-caller name ("Agent"), `handle`
  else `CallTarget.defaultHandle(for:)`. Only then does it touch state (`incomingRinging`)
  or the delegate: right after the report it asks the delegate for the target
  (`IncomingCall` carries the push's inline room, if any), so an answer that beats
  CallKit's completion still connects. In the report's completion it corrects the ring
  with `updateCall` when the target's name or handle differ (applied to that call id
  even if it was already answered), and fails gracefully for an unknown target;
  PushKit's completion runs after that on every path. A busy push is resolved and
  corrected only once CallKit accepts it, and ended only if the report succeeded. A malformed push
  (no valid `target_id`/`agent_id`) is reported under a minted id and ended, with no
  state change. A push or `placeCall` arriving while a finished call is still terminal
  first resets to idle (it is not busy); one during a live or ringing call takes the busy path. On `providerPerformAnswerCall` → `answer()` reuses the shared
  `connectTransport(for:)` — hybrid credentials: the host's target returns the inline
  push room/token if present, else the agent's own pairing endpoint or direct room. Decline while ringing logs `.declined`; the call
  log records `direction` (`.incoming`/`.outgoing`). Edge paths are first-class: a push
  mid-call **reports then immediately ends** under the push's own id (iOS kills the app
  for an unreported VoIP push — `bugs.md`); a Focus/DND-filtered ring logs as missed and
  returns to `.idle`; both post a quiet local notification (`MissedCallNotifying`,
  provisional auth). If the push carried a `status_url`, the engine reports the
  ring's terminal status back (`RingStatusReporting`: answered / declined / busy /
  suppressed_by_focus). The engine owns PushKit (`startPushRegistration()` at launch,
  `voipPushToken`); token registration fires on each token update
  (`AgentCallHost`, via `didUpdateVoIPPushToken`) *and* at agent save
  (`InboundRegistering`), through `PushTokenRegistrar` (`Core/Services/Push/`),
  sending the agent's name (at most 120 Unicode scalars; the ring corrects a
  shortened name once the target resolves) and synthetic email with the token;
  deleting an agent best-effort **unregisters** (DELETE on the registration
  endpoint, `PushTokenRegistrar.unregister`).
  Push/CallKit-incoming/entitlement are device-only; the engine's ring paths and
  payload parsing are unit-tested in the package, the host's registration and
  history in `ConduitTests/AgentCalls/`. See [INBOUND_CALLS](./INBOUND_CALLS.md).

## In-call surface — `InCallView`

`Features/InCall/InCallView.swift` is a pure projection of `CallEngine`
— it owns no call logic; every control forwards intent to the engine. It
presents as a `.fullScreenCover` from `RootTabView`, gated on
`state.isActive && !environment.isCallScreenMinimized`.

- **Per-agent color.** The screen takes its identity from the agent, not the app:
  a top-down wash in the agent's `AgentColor` (saturated avatar up top, fading to
  near-black where the controls sit) under a thin scrim so white name/status stay
  legible on the lighter palette colors. `AgentColor` (`Core/Models/AgentColor.swift`)
  is a curated set of eight iOS system colors, resolved against a fixed **dark**
  trait so an agent looks identical in light or dark mode. The slot is stamped
  concrete at creation (frozen on rename) into `Agent.colorTokenRaw`; the shared
  `AgentAvatarView` draws a `person.fill` glyph on that color when there's no photo,
  so the same color flows through Recents / Contacts / AgentDetail / in-call for
  free. The Add/Edit sheet's swatch row pre-selects the name-derived slot.
- **Status line.** Mirrors `CallState` (and so agrees with the spoken announcer):
  `Connecting…`, `Reconnecting…`, the failure hint, or — once connected — the live
  timer prefixed with the transport (`LiveKit · 1:23`). `Paused` while interrupted.
- **Controls** group into one frosted pill: Mute (or Push-to-Talk when always-on
  listening is off), the Daily-backed route menu, and the red End; the PTT caption
  sits below the pill.
- **Active-speaker ring.** A subtle ring around the avatar while the agent speaks
  (`ActiveSpeakerRingModifier`, binary on `isBotSpeaking`) — the group-FaceTime
  "active tile" cue, replacing the old amplitude glow.
- **Minimize / return.** A down-chevron (top-left, `closeButton` id, "Minimize")
  sets `AppEnvironment.isCallScreenMinimized`, which dismisses only the projection —
  the engine, transport, and audio session stay up (the view has no
  call-ending teardown; ending is exclusively the End button / hangup signal).
  Returning to the foreground with a still-active minimized call (e.g. tapping the
  CallKit Dynamic Island / status-bar pill) clears the flag and re-presents — the
  same consume-on-`.active` pattern `RootTabView` uses for `pendingSiriCall`. A call
  that ends while minimized is reset in `RootTabView` (no in-view auto-reset to run).

## Reconnection + spoken state

A dropped media connection while CallKit still believes the call is up is the
defining driving problem. Reconnection is **event-driven**: each
`.disconnected(.networkDropped)` is one attempt; `ReconnectionPolicy`
(package, `Models/`, pure: `base * 2^(n-1)` capped, default 6 attempts / 1 s / 30 s)
gates the budget; a `.connected` recovers and resets; exhaustion →
`failed(.lostConnection)`. A transport that self-heals may emit `.reconnecting`
(display-only — it does not count against the budget). *No jitter:* this is a
single client calling one agent, so there is no thundering-herd to spread.

`SpokenStateAnnouncing` (`Core/Services/Audio/`) speaks connection state in a
deliberately robotic built-in voice, distinct from the agent's, since the agent is
exactly what's unreachable: "Retrying connection" repeats on a ~7 s cadence,
"Connected"/"Disconnected" once, and `.connecting` plays a looped phone ringback
tone instead of speaking. The real `SpeechSpokenStateAnnouncer` uses
`AVSpeechSynthesizer` and the system-sound server for the tone; it must mix with
(never deactivate) the CallKit-owned session — that ducking/session wiring is
finalized in WS-3. `AgentCallHost` drives it from engine transitions.

## Audio-session / CallKit integration (built, M3)

`SystemCallProvider` (package, `CallKit/`) wraps `CXProvider` + `CXCallController`
and bridges the `CXProviderDelegate` callbacks onto `CallProviderDelegate`. The
`CXProviderDelegate` methods are `nonisolated` and hop onto the main actor via
`MainActor.assumeIsolated` (the delegate queue is `nil` → the main queue).
`SystemAudioSession` (`AudioSessionActivating`) pre-configures the session
(`.playAndRecord` / `.voiceChat`, Bluetooth + A2DP + duck) **without activating
it** — CallKit activates, the engine attaches media in `providerDidActivate`. The
speaker default is applied later, through the transport's device list (see the
hands-free default above). The seam was device-verified end-to-end in M3: connect + two-way audio +
Dynamic Island pill + lock-screen call screen + clean teardown.

On an outgoing call, `SystemCallProvider` reports a `CXCallUpdate` with
`localizedCallerName` set to the agent's name, so the call/lock screen shows the
name rather than the raw synthetic email handle. The **photo** (and Contacts/Siri
matching) comes from the optional system contact above; the name shows with or
without it. Device-only (CallKit doesn't run in the sim). Audio-interruption
handling now has a seam (see the call state machine above); yielding the route to a
real incoming PSTN call (`setOnHold`) remains the device-flagged follow-up.

## Siri dialing (built, M10 layers 1–2)

Three layers, one funnel, under `Core/Services/Siri/`. Every layer resolves the
spoken name to an agent UUID (the pure, tiered `AgentNameMatcher`: exact →
prefix → word-boundary contains, case/diacritic-folded) and sets
`AppEnvironment.pendingSiriCall`; `RootTabView` consumes it **only when
`scenePhase == .active`** and no call is up, then calls the one true entry point
`environment.placeCall(agent)`. The gate is load-bearing: CallKit rejects
`CXStartCallAction` from a not-yet-foregrounded app (cold-launch-from-Siri race),
which is also why `CallAgentIntent.openAppWhenRun = true` and why `perform()`
never dials directly.

1. **App Intents** — `CallAgentIntent` + `AgentEntity`/`AgentEntityQuery` +
   `ConduitAppShortcuts` ("Call \(agent) on Conduit" phrase family + static
   fallbacks with spoken disambiguation). Vocabulary refresh:
   `ConduitAppShortcuts.refreshParameters()` at launch and at all four agent
   mutation sites (VM save, both delete sites). The intent doubles as a
   composable **Shortcuts action** (user automations can dial agents).
   `CallAgentIntent`/`@Parameter agent` names are **frozen** — App Shortcut
   identity keys on them, and the iOS 27 `.phone.startCall` schema (layer 3,
   pending the Xcode 27 SDK) must upgrade the same type in place.
2. **SiriKit** — `SiriCallHandler` (`INStartCallIntentHandling`, in-app via
   `AppDelegate.application(_:handlerFor:)`, no extension target) covers
   "call \<agent\>" without the app name plus the calling domain's
   lock-screen/CarPlay special-casing pre-iOS 27. It responds `.continueInApp`;
   `ConduitApp.onContinueUserActivity` extracts the agent UUID from the
   `INPerson.customIdentifier` and feeds the funnel. Handles use the contact
   mirror's synthetic email so Siri shows the agent's card.

Config: Siri entitlement (project.yml → regenerated entitlements),
`NSSiriUsageDescription`, `INIntentsSupported`, `NSUserActivityTypes` in
Info.plist, and a one-time `INPreferences.requestSiriAuthorization` at launch —
without it, Settings' "Use with Siri Requests" defaults OFF and Siri claims the
app has no support. Locked-phone asymmetry (device-verified): the SiriKit
app-picker path dials from the lock screen; the App Shortcut path can't (it
must open the app) and Siri's refusal message is misleadingly generic.

## Shared utilities

- **`Log`** (`Core/Utilities/Log.swift`) — categorized os.log facade. See
  [CONVENTIONS § Logging](./CONVENTIONS.md#logging). The package has its own
  package-internal `Log` with the same labels and subsystem (the host app's bundle
  id), so engine lines group with the app's in Console.
- **`AccessibilityID`** (`Core/Utilities/AccessibilityID.swift`) — base namespace
  for accessibility identifiers. See
  [CONVENTIONS § Accessibility](./CONVENTIONS.md#accessibility--the-accessibilityid-convention).
