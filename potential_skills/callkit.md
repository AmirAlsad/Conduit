# CallKit ↔ transport timing

Pre-flight checklist for the CallKit/audio/transport seam. CallKit's request→delegate
round-trips and its activation timing are driven by the system, not your call site —
and the in-app fakes don't model that round-trip, so these bugs pass the sim suite and
only appear on device. Read before touching `CallEngine`, `SystemCallProvider`,
or a `CallTransport` adapter's connect/audio path. All of it is in the
`ConduitCallEngine` package (github.com/AmirAlsad/ConduitCallEngine): `CallEngine` in
`Sources/ConduitCallEngine/Call/`, `SystemCallProvider` in `…/CallKit/`, the Daily
and LiveKit adapters in `Sources/ConduitCallEngineDaily` / `…LiveKit`. The app's
SmallWebRTC adapter is `Conduit/Core/Services/Transport/`.

### System callbacks fire more than once and out of order vs. your code
First seen: 2026-06-07
Last seen: 2026-11-12
Occurrences: 5

**Pattern:** Logic that assumes a single, ordered sequence breaks when CallKit
re-enters or reorders. (1) Ending a call by requesting the system end AND driving the
terminal transition double-fired, because the real `CXEndCallAction` round-trips back
through `providerPerformEndCall` (two call-log rows). (2) `providerDidActivate` fired
BEFORE the transport finished connecting (a slow pairing fetch), so a one-shot
`setMicEnabled` no-op'd on a not-yet-joined client (dead mic). (3) `LiveKitTransport.connect()`
unconditionally reset `setEngineAvailability(.none)` after its pairing fetch, stomping
an activation that had already attached (`.default`) mid-fetch — dead mic on the first
call after a cold launch, where the fetch is slowest. (4) An activation that landed before
the engine had created the transport (while dialing, or before `answer()`) attached
nothing, and an End during `startOutgoingCall` was overwritten when the await returned.
(5) After a phone call on iOS 27, edges never came at all: no un-hold, no
`didActivate` after the app's resume, no interruption-ended notification, so the
call stayed resumed, silent and "interrupted".

**Rule:**
- Make every terminal transition idempotent (`guard !state.isTerminal`) and clear
  `activeCallID` on teardown, so a late/duplicate system callback is inert.
- Treat audio activation and transport-connected as two unordered edges: re-apply
  mic/route state on BOTH (`providerDidActivate` and `.connected`), gated by an
  `isAudioActivated` flag, so whichever lands last leaves the correct state.
- Never assume "I requested X, so X happens once, now." The system decides when and
  how many times.
- Never wait on a single system edge with no bound: give every wait a second edge
  that also ends it (an activation of a call that is not held ends an interruption)
  or a bounded re-request (a resume with no activation is asked for again).
- After every `await` on the call path, re-check it is still the same call (state,
  transport identity) before acting; a transport created after activation attaches at once.

**Why it's missed:** The fakes (`FakeCallProvider`, `FakeTransport`, in the package's
`ConduitCallEngineTesting`) don't round-trip
through the delegate and aren't connection-gated, so the unit suite shows one clean
ordered pass. The misbehavior is device-only — verify the call lifecycle on hardware,
and when a device bug appears, add the diagnostic to the debug spike's file log
(`Conduit/Debug/DebugCallKitSpike.swift`; os.log isn't capturable with the env-driven launch).

### A transport's connect overlaps another connect, or a disconnect, on the same session
First seen: 2026-11-11
Last seen: 2026-11-12
Occurrences: 3

**Pattern:** The engine calls `connect(_:)` on the same transport again while the
previous attempt's join is still in flight or joined without a ready bot (its join
deadline ran out, a hold paused it and the resume started another, a pre-connected
ring's preparation failed after the answer), and calls `disconnect()` whenever the
call ends, including mid-join. Adapters that keyed on the SDK's state alone refused
the fresh credentials (Daily "still in the call"), let two SDK connects run on one
room or client (LiveKit's `Room`, SmallWebRTC's `PipecatClient` during
`initDevices`), or closed a join under the SDK so it completed with no owner.

**Rule:**
- Own the join: run the SDK connect in a task the adapter keeps, and give each
  `connect(_:)` a generation; after every await, an older connect that lost the
  transport throws and touches nothing.
- A connect reports `.connected` again only for a live attempt whose agent is ready;
  anything else still up is taken over without the end-call signal (the agent of the
  fresh credentials may share the room) and with a new client.
- `disconnect()` lets a join in flight finish within a bound, then signals and leaves.
- `send(_:)` returns `.sent` only for a message handed to an open channel.

**Why it's missed:** `FakeTransport` resolves connects at once and in order, so no
test overlaps them; the adapters are device-only. Gate-level tests on the pure
deciders (`DailyConnectionGate`, `LiveKitConnectGate`, `SmallWebRTCConnectionGate`)
are what can pin the rules.

### A transport SDK with no preferred device moves the call to the loudspeaker
First seen: 2026-11-12
Last seen: 2026-11-12
Occurrences: 2

**Pattern:** Daily's SDK and the SmallWebRTC SDK both configure `AVAudioSession`
themselves, and with no preferred device both set the video-chat mode, which iOS
plays on the loudspeaker, at the join and again after route changes. A call CallKit
started on the earpiece moved to the speaker while connecting once the engine
stopped asking for the speaker itself.

**Rule:** For a transport whose SDK manages the session, always give the SDK a
preferred device through its own device API, before its join: the route the call is
on at the first attach, with the engine's request winning (`DailyAudioRouteGate` in
the package, `SmallWebRTCAudioRouteGate` in the app). Never force the session
yourself; the SDK re-applies its own choice over it.

**Why it's missed:** The fakes do not model the SDK's session management, and a
speaker default in the engine hid it (the SDK's loudspeaker was what was asked for).
