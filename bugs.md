# Bug Log

Auto-memory: bugs hit while working, newest first. Check here (and
`potential_skills/`) before debugging. On the 2nd occurrence of a class of bug,
promote it to `potential_skills/<domain>.md`. Format/lifecycle:
`potential_skills/README.md`.

---

### Mic stays off when CallKit activates before the transport connects
First seen: 2026-06-08 (M5b, pairing-flow device test)

**Pattern:** With the pairing flow, `transport.connect` does an HTTP POST
(`PairingClient`) before joining Daily, which delays the join. CallKit, meanwhile,
fires `providerDidActivate` right after the start action is fulfilled — i.e.
BEFORE the transport is connected. The coordinator's `activate(_:)` called
`setMicEnabled(true)` once, but Daily's `enableMic` is a no-op on a not-yet-joined
client, so the mic never came on (no uplink, no permission prompt) even though
downlink audio played (Daily manages its own session). The direct path connected
fast enough to win the race, so it never showed. Device log proved the order:
`audioActivated=true` → `connected`.

**Fix/Rule:** Don't treat audio-activation as a one-shot mic enable. Re-apply the
mic state whenever EITHER edge fires — on `providerDidActivate` AND on `.connected`
(gated by an `isAudioActivated` flag) — so whichever lands last turns the mic on.

**Why it's missed:** `FakeTransport.setMicEnabled` isn't connection-gated (it flips
the flag regardless), so the race is invisible in the unit suite; only a real
Daily client on device exhibits the no-op-before-join. See `potential_skills/callkit.md`.

### snapshot_ui returns 0×0 / coordinate taps no-op (UI automation flaky)
First seen: 2026-06-08 (WS-5 batch 1, verifying the Contacts/Add flow)

**Pattern:** `snapshot_ui` reports the app frame as `{0,0}` with no children even
though the app is fully rendered (the `screenshot` is correct). When the tree is in
this state, `tap` by coordinate also silently no-ops (it relies on the same
accessibility injection). CLAUDE.md attributes the 0×0 tree to iOS 26, but it also
hit on the **iOS 18.6** "iPhone 16" sim after a rapid reinstall + foreground
relaunch (the relaunch reused the same PID instead of restarting). TabView `Tab`
items also never appear as their own a11y elements, so tabs can't be tapped by
id/label regardless.

**Rule:** Don't block verification on interactive UI driving. Verify logic with
unit tests (sim, deterministic) and rendering with `screenshot`. If you must drive
the UI: fully terminate the app first (don't just relaunch), or reboot the sim, to
get a fresh a11y tree; tap tab-bar items by coordinate only.

**Why it's missed:** `screenshot` looks perfect, so the screen seems automatable;
the 0×0 tree only shows up when you query it, and a "successful" tap that does
nothing reads like a wrong coordinate rather than a dead injection path.

### Daily/WebRTC audio aborts in the iOS Simulator (device-only)
First seen: 2026-06-07 (M2 connect-and-downlink)

**Pattern:** Calling `transport.connect` (joining a Daily room) from the iOS
Simulator crashes with SIGABRT in Daily's bundled WebRTC audio device module:
`webrtc::ios_adm::AudioDeviceIOS::InitPlayout` → `AURemoteIO::Initialize` /
`AUVoiceIO::SetProperty` → AudioToolbox `_ReportRPCTimeout` → `abort`. The
voice-processing I/O (VPIO) audio unit WebRTC uses for echo cancellation has no
working HAL in the simulator. Pairing (`/connect`) and SDP/media negotiation
succeed first, so it looks like a mid-connect crash, not an audio-unit limit.

**Rule:** Anything that brings up Daily/WebRTC audio is **device-only**. Guard sim
paths with `#if targetEnvironment(simulator)` to pair/negotiate but skip the audio
connect. Verify real connect + downlink + two-way audio on a device.

**Why it's missed:** The abort is on a background WebRTC thread (uncatchable
SIGABRT), deep in the SDK, and only after pairing/negotiation appear to succeed.

### CallKit terminal transitions must be idempotent (end round-trips)
First seen: 2026-06-07 (M1 review, before commit)

**Pattern:** The in-app End path requested the system end (`callProvider.endCall(id)`)
*and* immediately drove the terminal transition (`finishEnded`). On a real
`CXProvider`, `endCall` performs a `CXEndCallAction`, which calls back into
`CXProviderDelegate.provider(_:perform: CXEndCallAction)` → our
`providerPerformEndCall` → `finishEnded` **a second time** → two `CallLogEntry`
rows and a double transport teardown for one call. The unit suite passed because
`FakeCallProvider.endCall` does not round-trip to the delegate, masking it.

**Rule:** Every terminal entry point (`fail` / `endRemote` / `finishEnded`) guards
`guard !state.isTerminal else { return }`, and `activeCallID` is cleared on
teardown so stray late callbacks are inert. When the real `SystemCallProvider`
lands (WS-3), keep this invariant; do not assume one End = one callback.

**Why it's missed:** Fakes that don't model CallKit's request→delegate round-trip
make double-fire invisible in the simulator; it only manifests on device.
