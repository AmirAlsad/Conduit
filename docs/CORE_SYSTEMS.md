# Core Systems

The shared, app-agnostic infrastructure under `Conduit/Core/`. Built so far: the
foundation (M0), the call state machine (M1), the Daily transport (M2), the
CallKit + audio-session seam (M3), the Keychain real + persistence (WS-4), and the
native LiveKit transport (M6). Every external boundary has a protocol seam and an
in-app fake, so everything above them is testable at sim speed today.

## The testability spine: protocol seams + fakes

Every stateful external boundary is a protocol with a real implementation (some
pending) and an in-app fake. **No concrete CallKit / Pipecat / Keychain type is
referenced outside its own service folder** — ViewModels and the coordinator see
only protocols. Fakes live in the **app target** (not the test target) so the unit
suite, SwiftUI previews, and the future CallKit-free debug path all reuse them.

| Seam | Protocol (`Core/Services/…`) | Fake (present) | Real (status) |
|---|---|---|---|
| CallKit | `CallProviding` + `CallProviderDelegate` + `AudioSessionActivating` (`CallKit/`) | `FakeCallProvider` / `FakeAudioSession` | `SystemCallProvider` (built, M3) |
| Audio interruptions | `AudioInterruptionObserving` + `…Delegate` (`CallKit/`) | `FakeAudioInterruptionObserver` | `SystemAudioInterruptionObserver` (built; audio device-only) |
| Transport | `Transport` (`Transport/`) | `FakeTransport` | `PipecatDailyTransport` (built, M2); `LiveKitTransport` (built, M6); `PipecatSmallWebRTCTransport` (built, M9) |
| Keychain | `KeychainStoring` (`Keychain/`) | `InMemoryKeychain` | `KeychainService` (built, WS-4) |
| Contacts sync | `ContactSyncing` (`Contacts/`) | `FakeContactSync` | `ContactSyncService` (built) |
| Persistence | `AgentRepository` (`Persistence/`) | — | `SwiftDataAgentRepository` (built) |

*Adding* an agent to Contacts has no seam — it goes through the system
`CNContactViewController` (see below), so there is no store round-trip to abstract.
Only *updating* a linked contact (sync-on-save) touches `CNContactStore`, behind
the `ContactSyncing` seam above.

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

`LiveKitTransport` (`Transport/`, M6) is the native second transport over
`livekit/client-sdk-swift`, behind the same protocol. It re-derives the RTVI-style
signals from LiveKit: `.connected` only when the room **and** the agent (a remote
participant) are both ready — the pure, unit-tested `LiveKitConnectGate` — and
bot-speaking from `didUpdateSpeakingParticipants`. It reuses `PairingClient` (the
pairing contract is transport-neutral; the response's `room_url` is LiveKit's `wss://`
URL). The decisive difference from Daily is **manual audio**: at init it sets
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

`PipecatSmallWebRTCTransport` (`Transport/`, M9) is the zero-cloud third
transport: peer-to-peer WebRTC straight to the user's own Pipecat server (LAN /
self-hosted — UDP media, so never behind an HTTP-only host). It mirrors the Daily
adapter (`PipecatClient` + the package's `SmallWebRTCTransport`); pairing returns
the engine's **offer URL** + a short-lived bearer as `room_url`/`token`, and the
SDK POSTs the SDP offer / PATCHes trickle-ICE to that URL with the bearer
attached. Audio follows the **Daily pattern** (SDK owns the session config; joins
mic-disabled; attach/detach no-ops). **Load-bearing:** the stock package's
stasel/WebRTC collides with Daily's embedded WebRTC (un-prefixed `RTC*` classes
duplicated → Daily calls crash), so `project.yml` pins our fork built against
`LiveKitWebRTC` — see `bugs.md` and ROADMAP M9 before bumping any transport SDK.

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
`transportFactory: (TransportKind) -> Transport`, and the app-wide
`CallSessionCoordinator`. `inMemory()` wires the fakes + an in-memory store
(previews, tests). `live()` (what `ConduitApp` runs on) wires the real services —
`KeychainService`, a persistent SwiftData store, and `SpeechSpokenStateAnnouncer`.
CallKit (`SystemCallProvider`) and the Daily transport can't run in the simulator,
so `live()` falls back to the call/transport fakes there via
`#if targetEnvironment(simulator)` while keeping Keychain/persistence real on both
— so a real call is device-only, but add-agent / token / persistence work in the
sim. `ConduitApp` injects the environment via `.environment(_:)` +
`.modelContainer(_:)`.

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
  / `declined` / `noAnswer` / `canceled`), transport kind.

`Agent` 1—* `CallLogEntry` with `@Relationship(.cascade)`: deleting an agent wipes
its log; deleting a single entry nullifies its `agent` and removes only that row
(history removed, agent kept). The **synthetic handle** (`Agent+Handle.swift`) is
minted once from the immutable `id` as `<slug>-<id8>.agent.conduit.invalid` — an
email-type handle on the reserved `.invalid` TLD, so Siri/CallKit read the display
name rather than the raw ID. `AgentRepository` (main-actor) wraps `ModelContext`
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
field. `CallSessionCoordinator.loadToken` reads whichever the call uses (pairing
wins when both are set). The round-trip is unit-tested on the simulator under a
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

## Call state machine — `CallSessionCoordinator`

`Core/Services/Call/CallSessionCoordinator.swift` — a `@MainActor @Observable`
type that is the single source of truth for a call and the orchestration point
between the CallKit and transport seams. It lives in `Core/Services/Call/` (not in
`Features/InCall/`) because it is an app-wide service owned by `AppEnvironment` and
consumed by multiple features (Recents redial, Contacts/AgentDetail call, the
InCall projection). It conforms to `CallProviderDelegate` and
`AudioInterruptionObserverDelegate`.

`CallState` (`Core/Models/CallState.swift`, pure/`Equatable`):

```
idle → dialing → connecting → connected(since:) → reconnecting(attempt:) ⇄ connected
                                                 ↘ ended(CallOutcome) | failed(CallFailureReason)
incomingRinging → connecting → …   (agent-initiated inbound, after the user answers)
```

`incomingRinging` is the one non-idle state with `isActive == false`: while it
rings, CallKit's system UI is primary, so the app shows no surface until answer.

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
- **Audio interruptions.** `AudioInterruptionObserving` (real:
  `SystemAudioInterruptionObserver` over `AVAudioSession.interruptionNotification`)
  drives `isInterrupted`: on `.began` the mic pauses (`setMicEnabled(false)`); on
  `.ended(shouldResume:)` it re-applies the correct mic state via `applyMicIfActivated`
  (respecting mute / push-to-talk). The session is never touched — CallKit owns it and
  re-fires `providerDidActivate` after an interruption, so the two are unordered edges
  that both re-apply mic state idempotently. Transient GPS/nav ducking is system-managed
  by `.duckOthers`; this observer covers full takeovers (Siri, a phone call). The live
  audio behavior is device-only; the begin/resume logic is unit-tested via the fake.
- **Inbound (agent-initiated) calls.** A VoIP push (PushKit) → `receiveCall(_:)` resolves
  the agent, reports an incoming call to CallKit (`reportIncomingCall`), and rings in
  `incomingRinging`. On `providerPerformAnswerCall` → `answer()` reuses the shared
  `connectTransport(for:inlineCreds:)` — hybrid credentials: inline push room/token if
  present, else `PairingClient.resolve`. Decline while ringing logs `.declined`; the call
  log records `direction` (`.incoming`/`.outgoing`). Edge paths are first-class: a push
  mid-call **reports then immediately ends** under the push's own id (iOS kills the app
  for an unreported VoIP push — `bugs.md`); a Focus/DND-filtered ring logs as missed and
  returns to `.idle`; both post a quiet local notification (`MissedCallNotifying`,
  provisional auth). If the push carried a `status_url`, the coordinator reports the
  ring's terminal status back (`RingStatusReporting`: answered / declined / busy /
  suppressed_by_focus). Token registration fires on app launch (`VoIPPushService`) *and*
  at agent save (`InboundRegistering`); deleting an agent best-effort **unregisters**
  (DELETE on the registration endpoint, `PushTokenRegistrar.unregister`).
  Push/CallKit-incoming/entitlement are device-only; the coordinator paths + payload
  parsing are unit-tested. See [INBOUND_CALLS](./INBOUND_CALLS.md).

## In-call surface — `InCallView`

`Features/InCall/InCallView.swift` is a pure projection of `CallSessionCoordinator`
— it owns no call logic; every control forwards intent to the coordinator. It
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
  the coordinator, transport, and audio session stay up (the view has no
  call-ending teardown; ending is exclusively the End button / hangup signal).
  Returning to the foreground with a still-active minimized call (e.g. tapping the
  CallKit Dynamic Island / status-bar pill) clears the flag and re-presents — the
  same consume-on-`.active` pattern `RootTabView` uses for `pendingSiriCall`. A call
  that ends while minimized is reset in `RootTabView` (no in-view auto-reset to run).

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
`callSession.placeCall(agent)`. The gate is load-bearing: CallKit rejects
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
  [CONVENTIONS § Logging](./CONVENTIONS.md#logging).
- **`AccessibilityID`** (`Core/Utilities/AccessibilityID.swift`) — base namespace
  for accessibility identifiers. See
  [CONVENTIONS § Accessibility](./CONVENTIONS.md#accessibility--the-accessibilityid-convention).
