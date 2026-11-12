# Core Systems

The shared infrastructure under `Conduit/Core/` and the engine package it sits on.
Built so far: the foundation (M0), the call state machine (M1), the Daily transport
(M2), the CallKit + audio-session seam (M3), the Keychain real + persistence (WS-4),
the native LiveKit transport (M6), and the adoption of engine 0.2 (call hold,
pre-connect, ring timeouts and cancels, call-control signals, engine-driven cues, a
join deadline). Every external boundary has a protocol seam and a fake, so
everything above them is testable at sim speed.

**Verification status.** Device runs are recorded in
[DEVICE_VERIFICATION](./DEVICE_VERIFICATION.md). Statements below that something was
"device-verified" date to the runs they name (June and November 2026, engine 0.1.x
and the SDK versions of the time). Everything the 0.2 adoption added is **built and
unit-tested; device verification pending**: a session is planned and has not run.

## Where the code lives

The call engine is the Swift package **`ConduitCallEngine`**, extracted from this
app. `project.yml` consumes it by version from
`github.com/AmirAlsad/ConduitCallEngine` (`minorVersion: "0.2.0"`, 0.2.x only),
pinned in the tracked `Package.resolved`, which also pins the transport SDKs
(Pipecat iOS client 1.3.0 and its Daily transport, Daily 0.41.0, LiveKit 2.19.0,
the SmallWebRTC fork by revision; bumped with the 0.2 adoption, regression calls on
them pending). The app links four of the package's products:

| Product | Holds |
|---|---|
| `ConduitCallEngine` | `CallEngine` (the state machine) and its host surface (`CallEngineDelegate`, `CallEngineConfiguration`, `CallTarget`, `ActiveCall`, `IncomingCall`, `CallRecord`); `CallState` and the outcome / failure / direction models; `CallTransport` with `TransportEvent`, `TransportError`, `CallConnection`, `CallSignal` / `CallSignalDelivery`, `AudioDeviceInfo`, `AudioRouteKind`; `ConnectRequest`, `RingPreparation`, `CallCue`; the CallKit provider, audio-session and audio-interruption seams; PushKit registration and incoming-push parsing; ring-status receipts; `ReconnectionPolicy`; `CallEngineLog`. Imports no transport SDK. |
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
| Missed-call notification | `MissedCallNotifying` (`Push/`) | `FakeMissedCallNotifier` | `MissedCallNotifier` (built) |
| Microphone permission | `MicrophonePermissionProviding` (`Audio/`) | `FakeMicrophonePermission` | `SystemMicrophonePermission` (built) |
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
display name, handle, `ringPreparation`, `makeTransport`, `connect`); it calls
`makeTransport()` and subscribes **first**, then awaits `target.connect(request)`
for the credentials (the `ConnectRequest` says why it asks), then joins — so a
CallKit activation that lands mid-fetch still reaches `attachAudioSession()`.
`target.connect` re-runs for every reconnect attempt, and `makeTransport` can run
twice for one incoming call (for the ring, and again at the answer if the
preparation failed).
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
Daily heals short network outages inside its SDK without changing the Pipecat
transport state, so the client callbacks never report them. The adapter infers
them from the device's network path instead: once the call has reported
`.connected` it watches an `NWPathMonitor` (behind the package-internal
`NetworkPathMonitoring` seam), and the pure, unit-tested `DailyInterruptionGate`
turns a lost path into one `.reconnecting` and its return into `.connected`
(none after a transport disconnect or a hangup; a fresh gate per connect attempt).
It reflects the path, not Daily's media state: a dead-but-associated Wi-Fi is not
caught, and "Connected" can be announced a moment before audio resumes. Daily has
no playout control, so the adapter silences a **held** call by unsubscribing from
the agent's audio on detach and subscribing again on attach (a held call that
reconnects joins unsubscribed); it sends client messages once the call is joined,
releases its Pipecat client on `disconnect()`, and takes over a session whose bot
never got ready instead of refusing it, while refusing (and leaving alone) a call
Daily is still healing. It declares `canConnectWhileRinging` true: a ring's join
(`connectWhileRinging`) unsubscribes from the agent's audio before it joins and
keeps it so until the first attach after the answer, which subscribes and returns
once Daily has it; for that join the agent being in the room counts as ready (the
bot cannot report ready unheard). Every other join keeps Daily's default
subscriptions and waits for bot-ready. Device-observed on one phone (iPhone 17,
iOS 27.0, locked): silent rings of up to 20 s, clean agent audio at the answer,
route settled within ~0.3 s; joining with default subscriptions during a ring had
left the call with no agent audio. The hold silencing is unit-tested only.

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
A reconnect the SDK reports complete goes back through that gate: it is `.connected`
only with the room connected and a remote present. The package requires LiveKit
2.18.0 or later, from which every reconnect the SDK gives up on ends with the room
disconnected (before it, 2.15.1 could report an abandoned reconnect as complete
during a long outage, which the November run caught and the adapter then worked
around); a rejoin into a room with no remote ends the call as the agent's hangup,
and a `connect` while LiveKit is still reconnecting throws instead of rejoining.
The adapter owns its joins (a `disconnect()` during a join waits for it, so the
device is never left in the room with the agent) and declares
`canConnectWhileRinging` true, because it touches no audio before the attach: a
`media` pre-connect ring joins the room while the phone rings. A held call stops
LiveKit's playout and capture on detach.

`PipecatSmallWebRTCTransport` (app, `Core/Services/Transport/`, M9) is the
zero-cloud third transport: peer-to-peer WebRTC straight to the user's own Pipecat
server (LAN / self-hosted — UDP media, so never behind an HTTP-only host). It is
host code conforming to the package's `CallTransport`, mirroring the Daily adapter
(`PipecatClient` + the package's `SmallWebRTCTransport`); pairing returns the
engine's **offer URL** + a short-lived bearer as `room_url`/`token`, and the SDK
POSTs the SDP offer / PATCHes trickle-ICE to that URL with the bearer attached.
Audio follows the **Daily pattern** (SDK owns the session config; joins
mic-disabled). `detachAudioSession()` turns capture off and `attachAudioSession()`
starts nothing (the engine's `setMicEnabled` reopens capture); the SDK exposes no
control over the agent's playout (its peer connection and remote track are
internal), so a **held** SmallWebRTC call is silent only because the agent honours
`call-held`. For the same reason (the SDK configures the session at connect) it
declares `canConnectWhileRinging` false, so a `media` pre-connect ring stays at
`credentials`. **Load-bearing:** the stock package's
stasel/WebRTC collides with Daily's embedded WebRTC (un-prefixed `RTC*` classes
duplicated → Daily calls crash), so `project.yml` pins our fork built against
`LiveKitWebRTC` — and the fork stays an **app-only** dependency, never one of the
engine package's. See `bugs.md` and ROADMAP M9 before bumping any transport SDK;
`scripts/check-bundle.sh <Conduit.app>` is the static check on the built app.
What each connect attempt reports is decided by `SmallWebRTCConnectionGate` (pure,
unit-tested), the same rules as the package's Daily adapter: one `.connected` per
attempt, and nothing that steers the engine once the attempt has reported a
disconnect, its connect has thrown, or the host has disconnected (so a failed
reconnect attempt is not counted twice, and a late bot-left cannot end a
reconnecting call). A connect that finds the session still up reports `.connected`
again only for a live attempt whose agent is ready; anything else still up (a join
in flight, a joined session whose bot never got ready, an attempt that is over, a
session leaving) is taken over, as the Daily adapter does: left without the
end-call signal, its client released, and the fresh credentials joined with a new
client. The adapter owns its joins: the SDK's connect runs in a task it keeps
(`SmallWebRTCJoin`), and each connect takes a ticket (`SmallWebRTCConnectLedger`),
so of overlapping connects only the newest owns the transport and an older one
throws without touching it; `disconnect()` lets a join in flight finish (2 s) so it
can tell the agent its offer started that the call is over. `send(_:)` returns
`.sent` only for a message handed to the open data channel of a live attempt,
`.failed` otherwise; the SDK reports nothing past that hand-off (it swallows send
errors and the data channel's result), and its connect never returns once its peer
connection was closed before the data channel opened, so a join closed that way is
left to the server's connection timeout. Every connect error is `.connectionFailed`:
the SDK's offer error has no status code, and a rejected API key is caught exactly
by pairing (`PairingError.unauthorized` → `.authenticationFailed`).

All three adapters send the engine's **`end-call` signal** in `disconnect()` — a
deliberate hangup ends the bot at once instead of burning its human-absent grace
window — and deliver the engine's **call-control signals** (`call-connected`,
`call-held`, `call-resumed`) from `send(_:)`, all as the same RTVI client message
(`{"label": "rtvi-ai", "type": "client-message", "data": {"t": …}}`). Daily and
SmallWebRTC send it through the Pipecat transport's message path once the call is
joined (Daily) or the data channel is open (SmallWebRTC), not
`PipecatClient.sendClientMessage`, which refuses until the bot is ready; LiveKit
publishes it on the data channel, because Pipecat's LiveKit input path doesn't
deliver client RTVI messages — see `bugs.md`. Reconnects never call `disconnect()`, so a genuine drop still gets
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

**DEBUG on a device.** `live()` starts the call trace
(`Debug/CallTrace.swift`, `conduit-call-trace.log` in Documents, timestamped,
kept across launches; past 2 MB it moves to `conduit-call-trace.previous.log`): the
launch, each
transport made, `AgentCallHost`'s view of every ring (call id, requested
pre-connect, inline or not), state change, cue, record and every
`ringPreparationPhase` change (from the delegate callback, so fast intermediate
phases are not lost), and, from `CallTraceObserver`, hold, audio activation (as
the engine counts it), interruption and mute; the call screen adds route
snapshots while it is up. `live()` also installs `CallEngineLog.handler`
(`CallTrace.captureEngineLog()`, DEBUG only, before the engine is created) so
every package log event (category, level, message), CallKit's raw audio
activations included, lands in the trace with its timestamp and still reaches
Console through `CallEngineLog.writeToOSLog`; Release builds leave the package's
logging at its default.

The **Cue Lab** (`Debug/CueLab/`, DEBUG only) is a panel on the call screen for
finding out why the spoken cues are inaudible on Daily calls and in the last retry
phase of a LiveKit outage. During a live call it plays one short cue through each
candidate path, one button each: `AVSpeechSynthesizer` speaking through the app's
audio session and through its own, the speech rendered to a file and played with
`AVAudioPlayer`, rendered to a buffer and played with `AVAudioEngine`; the ringback
with `AVAudioPlayer`, as a system sound and as an alert sound; and, on LiveKit
calls, the SDK's `SoundPlayer` for the speech and the ring, with two LiveKit
ducking switches. It never activates,
deactivates or reconfigures the audio session (CallKit owns it); every press logs
session and route snapshots before and after to the call trace. Which paths are
heard on which transport, from which output, is read off the tester's report and
the trace. The announcer's own mechanism is unchanged until that is known.

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
  failure reason and missed reason. Direction, outcome, failure reason and missed
  reason are the engine package's `CallDirection` / `CallOutcome` /
  `CallFailureReason` / `MissedCallReason`, stored as raw strings.
  The labels live in `CallFailureReason+Display`: a call whose agent never became
  ready within the engine's join deadline (`.agentUnreachable`) reads
  "Failed — agent didn't join" in Recents, with a hint on the call screen to check
  that the server starts its agent.

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
fires where a call ends (and for every missed ring), carrying a `missedReason` for
a ring nobody answered or declined (`busy`, `filteredByFocus`, `ringTimedOut`,
`canceledByCaller`); `callEngine(_:cue:)` delivers the moments to mark with a sound;
`didChangeRingPreparationPhaseFrom:to:` reports each phase of a ring's pre-connect;
`targetForIncomingCall` resolves a push to a
`CallTarget` (nil = unknown, the ring fails); `ringStatusBearerForTarget` supplies
the receipt bearer.

`Agent+CallTarget` builds each target's credential step from the engine's
`ConnectRequest` (`purpose`: `.outgoing`, `.answered`, `.ringing(joinsBeforeAnswer:)`
or `.reconnect(attempt:)`, plus the ring's `callID` for an incoming call). Inline
push credentials are returned for every purpose without a network call; a direct
agent returns its room; a pairing agent re-pairs every time, and a request made
while the phone rings adds `ring: {call_id, joins_before_answer}` to the pairing
body (`PairingRing`; `joins_before_answer` when the transport joins before the
answer), so the user's backend can dispatch its agent for that ring. Every pairing
request also lists the call-control signals the app's calls carry
(`call_signals`: `call-connected`, `call-held`, `call-resumed`), so the backend's
agent waits for `call-connected` before it greets. A backend that predates the
fields ignores them. **Pre-connect
policy:** `AgentCallHost` allows each ring whatever its push's `preconnect` asks
for (`CallTarget.ringPreparation = IncomingCall.requestedPreparation`), since the
sender is the user's own backend; the engine still lowers `media` to `credentials`
for a transport that cannot join while ringing (SmallWebRTC; LiveKit and Daily
join). Outgoing targets allow none. Conduit's delegate is `AgentCallHost`
(`Core/Services/AgentCalls/AgentCallHost.swift`): it writes `CallLogEntry` rows
(looking the agent up by target id — none, no row; the missed reason is stored as
`missedReasonRaw`, and Recents reads every missed ring as "Missed", in red, with
"— on another call" / "— Focus" for the two the user never heard), posts the
missed-call notification for every missed ring, donates outgoing calls to Siri on
`dialing → connecting`, and plays the engine's cues, choosing by the call
(`activeCall.direction`, `activeCall.wasReadyAtAnswer`): `.start(.connecting)` on a
call the user placed loops the ringback tone (starting `Ringback.startDelay`, 0.5 s,
after the cue, so it never starts while the call screen slides up and a call that
ends sooner never rings); on an answered call there is never a ringback, and if it is
still connecting `AgentCallHost.connectingPromptDelay` (1 s) after the answer it
says "Connecting" once per call (a hold before then waits again from the resume),
`.start(.retrying)` repeats "Retrying", `.stop` ends the loop at once,
`.moment(.connected)` / `.moment(.reconnected)` say "Connected" (the engine sends
`.moment(.connected)` only once CallKit has activated the call's audio, so it is
said into a live session), except `.moment(.connected)` of a call answered with its
agent already there, which says nothing, and
`.moment(.connectionLost)` says "Disconnected" (once per outage);
`.moment(.held)` and `.moment(.resumed)` play nothing. The engine
guarantees every loop is stopped by the time the call ends, a provider reset
included, and no cues for a ring that is never answered. **The connect sequence**
of a call the user placed: the engine holds the call in `.connecting` for at least
`Ringback.minimumOutgoingConnectingDuration` (the 0.5 s start delay plus the 2.1 s
audible tone, the engine's `minimumOutgoingConnectingDuration`) even when the
transport is ready sooner, so the first tone always plays in full and the state, the
call screen, CallKit and the cue stop together. An answered call is never held: it
connects as soon as its transport is ready, and a pre-connected ring answered with
its agent there skips `.connecting` altogether. The engine keeps the mic closed until
the call is connected, so neither the ringback nor "Connecting" needs anything. A
call answered with its agent there withholds nothing, so the engine sends
`call-connected` as soon as CallKit activates the audio. At every other
`.moment(.connected)` (and `.moment(.reconnected)`) the host keeps the mic closed with the engine's
`setMicWithheld(_:)` (not mute: the call screen and CallKit still show it unmuted)
until the announcer reports that "Connected" has finished
(`announce(_:completion:)`, from the synthesizer's didFinish/didCancel, or
`stopNow()` cutting it off), so the agent does not hear it through the mic (on the
speaker it would, and could take it for the user). The release opens the mic, and
the engine then tells the agent `call-connected`: the moment to start speaking.
The host releases at once when "Connected" will not come: the call ends or fails,
or a hold (`.moment(.held)`). "Disconnected" and "Retrying" are not withheld for: the
transport is down while they play. The engine ends a withhold with the call, and
releases one still in place 5 seconds after the call connected with its audio
activated (`micWithholdTimeout`), logging a warning, which also sends
`call-connected`. The engine runs a ring
for at most its `ringTimeout` (60 s) and waits at most `joinTimeout` (30 s) for the
agent after the transport's `connect` returns; the app keeps both defaults.

**Microphone permission.** Neither the engine nor the SDKs prompt reliably
(LiveKit 2.17+ never prompts, and refuses to unless the app is active), so the app
asks itself, through `MicrophonePermissionProviding` (`Audio/`; real:
`SystemMicrophonePermission` over `AVAudioApplication`): before every outgoing call
(`AppEnvironment.placeCall`; when refused, no call is placed and RootTabView
explains it with a way to Settings), and when "Let this agent call me" is turned on
(a refusal shows a note under the toggle; saving is not blocked). A first inbound
call answered from the lock screen on an install that never decided has no mic.

`CallState` (package, `Models/CallState.swift`, pure/`Equatable`):

```
idle → dialing → connecting → connected(since:) → reconnecting(attempt:) ⇄ connected
                                                 ↘ ended(CallOutcome) | failed(CallFailureReason)
incomingRinging → connecting → …   (agent-initiated inbound, after the user answers)
incomingRinging → connected → …    (answered while a pre-connected agent was there)
```

`incomingRinging` is the one non-idle state with `isActive == false`: while it
rings, CallKit's system UI is primary, so the app shows no surface until answer.

Key behaviors:

- **Audio-session ownership invariant.** `transport.attachAudioSession()` runs only
  after CallKit's `providerDidActivate` — from `activate(_:)`, or when the transport
  is created after activation already landed (e.g. CallKit activated while dialing
  or before `answer()` ran; it is replayed onto the new transport before the
  credential fetch) — and the mic is never enabled before activation. The mic
  follows one rule over every input (activation, interruption, in-app and system
  mute, push-to-talk, the transport reporting `.connected`), whatever order they
  arrive in; route reads and the hands-free default also wait for the activation,
  and an activation during an unanswered ring is ignored (it belongs to an
  earlier call).
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
  a never-connected drop → `failed(.transportError)`; a first connect whose agent
  is not ready within `joinTimeout` (30 s, the app keeps the default) →
  `failed(.agentUnreachable)`; a mid-call drop → reconnect.
- **Hold.** Calls are reported holdable (`supportsHolding`, the default), so a
  phone call the user takes holds the agent call instead of ending it, and the
  call screen's hold control calls `setOnHold(_:)`, which goes through CallKit.
  `isOnHold` does not change `state`; while held the engine closes the mic,
  detaches the transport's audio (on resume it attaches again once CallKit has
  re-activated the session), plays no cues, spends no reconnect retries and
  suspends the first connect's join deadline, and sends the agent `call-held`
  (`call-resumed` after). Held time counts toward the call's duration. A resume
  that CallKit does not follow with an audio activation within 2 s (seen after a
  phone call on iOS 27) is asked for again: the engine holds and resumes the call
  through CallKit, silently, up to 3 times per resume, stopping at the activation,
  a hold or the call's end, and never overriding a hold asked for meanwhile.
  CallKit does not resume an app's call when the phone call it was held for ends,
  so the engine does (`resumesAfterSystemHold`, default on, which the app keeps):
  for a hold iOS made (one not requested through `setOnHold`), it watches the
  device's calls through `CXCallObserver` and resumes once every other call seen
  during the hold has ended and none is left. A hold from the call screen's hold
  control is never resumed by the engine. The
  transport must stop and restart playout there: LiveKit and Daily do (Daily by
  unsubscribing from the agent's audio), SmallWebRTC cannot, so a held SmallWebRTC
  call is silent only if the agent honours `call-held`.
- **Call-control signals.** `send(_:)` on the transport carries `call-connected`,
  `call-held` and `call-resumed` (as RTVI client messages) and returns a
  `CallSignalDelivery` (`.sent`, `.failed`, `.unsupported`). The engine retries a
  `.failed` signal (after 1, 2, 4, 8, 16, 30 s) and repeats the call's state after
  every reconnect, never retries `.unsupported`, and counts an agent as possibly
  still held until a `call-resumed` is `.sent`. `call-connected` is sent on every
  call, once it is connected, CallKit has activated its audio, it is not held and
  the host is not withholding the mic (after "Connected"), and again after every
  reconnect.
- **Pre-connect (ringing).** Once CallKit has accepted a ring, the engine prepares
  it up to the lowest of the push's `preconnect`, the target's `ringPreparation` and
  what the transport can do. `credentials` runs the target's `connect` during the
  ring (`ConnectRequest.purpose == .ringing(joinsBeforeAnswer: false)`) and keeps the
  result; `media` also creates the transport and joins the room, with no attach, no
  mic and no route changes. `ringPreparationPhase` says how far it got (`state`
  stays `incomingRinging`). Answering a ring whose agent is there goes straight to
  `connected`. A failed preparation never ends the ring or makes the answered call
  worse than none: the answer then connects as without pre-connect. The agent
  leaving a ready ring before the answer ends it as the caller cancelling
  (`canceledByCaller`, a `canceled` receipt). A ring that ends unanswered disconnects
  the transport it prepared, sending `end-call` first if it was up. The app's
  host-side part is `PairingRing`: a pairing request made during a ring carries
  `ring: {call_id, joins_before_answer}`.
- **Audio interruptions.** `AudioInterruptionObserving` (real:
  `SystemAudioInterruptionObserver` over `AVAudioSession.interruptionNotification`)
  drives `isInterrupted`: on `.began` the mic pauses (`setMicEnabled(false)`); on
  `.ended(shouldResume:)` it re-applies the correct mic state (respecting mute /
  push-to-talk). The session is never touched — CallKit owns it and re-fires
  `providerDidActivate` after an interruption, so the two are unordered edges that
  both re-apply mic state idempotently. iOS does not always post the end (after a
  phone call on iOS 27 it never came), so CallKit activating the audio of a call that
  is not held ends the interruption by itself, as does resuming a call whose audio
  CallKit activated during the hold; an end without `shouldResume` still waits for
  an activation, an unmute or a push-to-talk press. Transient GPS/nav ducking is system-managed
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
  returns to `.idle`; so does a ring nobody answers within the ring timeout (60 s, or
  the push's shorter `ring_timeout`, never below 10 s) and one the server withdraws
  with a cancel push (`action: cancel`, remembered for 10 minutes so a late ring is
  ended at once);
  all four post a quiet local notification (`MissedCallNotifying`, provisional auth).
  If the push carried a `status_url`, the engine reports the ring's terminal status
  back (`RingStatusReporting`: answered / declined / busy / suppressed_by_focus /
  unanswered / canceled). The engine owns PushKit (`startPushRegistration()` at launch,
  `voipPushToken`); token registration fires on each token update
  (`AgentCallHost`, via `didUpdateVoIPPushToken`) *and* at agent save
  (`InboundRegistering`), through `PushTokenRegistrar` (`Core/Services/Push/`),
  sending the agent's name (at most 120 Unicode scalars; the ring corrects a
  shortened name once the target resolves), synthetic email and the engine's
  `supportedPushFeatures` (`push_features`), the call signals its calls carry
  (`call_signals`) and the agent's transport (`transport`, as in the pairing body,
  so a room the server prepares for a ring is one the app can join) with the token;
  deleting an agent best-effort **unregisters** (DELETE on the registration
  endpoint, `PushTokenRegistrar.unregister`). A token PushKit invalidates
  (`callEngineDidInvalidateVoIPPushToken`) is no longer current: the engine's
  `voipPushToken` is nil, so save-time registration sends nothing until a new one
  is issued, and a registration pass still sending the old token is cancelled.
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
  timer prefixed with the transport (`LiveKit · 1:23`). `On Hold` while the engine
  holds the call (over `Paused` while interrupted), never once it has ended.
  `Paused` clears when the interruption ends or CallKit hands the audio back; if it
  ever lingers on a call that is not held, the way out is the hold control (Hold,
  then Resume), which stays enabled while the call is connecting, connected or
  reconnecting and makes CallKit hand the audio back, or End.
- **Controls** group into one frosted pill: Mute (or Push-to-Talk when always-on
  listening is off), the Daily-backed route menu, Hold (filled while held; enabled
  while the call is connecting, connected or reconnecting; `InCall_HoldButton`) and
  the red End; the PTT caption sits below the pill.
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
  While minimized, the root tabs' return-to-call bar shows a pause glyph and
  "On Hold" for a held call.

## Reconnection + spoken state

A dropped media connection while CallKit still believes the call is up is the
defining driving problem. Reconnection is **event-driven**: each
`.disconnected(.networkDropped)` is one attempt; `ReconnectionPolicy`
(package, `Models/`, pure: `base * 2^(n-1)` capped, default 6 attempts / 1 s / 30 s)
gates the budget; a `.connected` recovers and resets; exhaustion →
`failed(.lostConnection)`. A transport that self-heals emits `.reconnecting`
(display-only — `reconnecting(0)`, it does not count against the budget), then
`.connected` or, if it gives up, `.disconnected`, which starts the engine's own
attempts from that display state; if neither comes within 30 s the engine runs its
own attempt on the same transport instance (which therefore has to handle a
`connect` while its session is still up), and an attempt whose join never reports
`.connected` is bounded by the join deadline. LiveKit reports its SDK's own reconnects this
way, and Daily its network-path interruptions (see the Daily adapter above); the
app's SmallWebRTC adapter does not. *No jitter:* this is a
single client calling one agent, so there is no thundering-herd to spread.

`SpokenStateAnnouncing` (`Core/Services/Audio/`) speaks connection state in a
deliberately robotic built-in voice, distinct from the agent's, since the agent is
exactly what's unreachable: "Retrying connection" repeats on a ~7 s cadence,
"Connected"/"Disconnected" once, and `.connecting` plays a looped phone ringback
tone (`Ringback`, `SystemRingback`) instead of speaking, starting 0.5 s after the cue,
for calls the user placed only; announced once, `.connecting` is spoken ("Connecting",
an answered call still connecting after a second). A stop silences the tone at once
(the engine's outgoing minimum connecting time covers the first tone), and `stopNow()` also cuts off speech in progress. The real `SpeechSpokenStateAnnouncer` uses
`AVSpeechSynthesizer` and the system-sound server for the tone; it must mix with
(never deactivate) the CallKit-owned session — that ducking/session wiring is
finalized in WS-3. `AgentCallHost` drives it from the engine's cue events (see
above), not from state transitions, so a loop stops by the time the call ends.

Known limitation (device-observed on the 0.1.1 run): the spoken cues were audible on
LiveKit calls but not during Daily calls, and they went silent during the final retry
phase of a LiveKit outage; the cause is not established. Moving to the engine's cues
changes *when* a cue plays, not how its audio is produced, so it is not expected to
fix this. The DEBUG Cue Lab (above) is how the cause is to be found, and which
mechanism the announcer should use is an open decision (see
[ROADMAP](./ROADMAP.md)); nothing about the announcer's audio path has changed.

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
handling now has a seam (see the call state machine above), and calls are holdable
(see Hold above); holding for a real incoming phone call, and the host-initiated
hold, are built and unit-tested; device verification pending.

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
