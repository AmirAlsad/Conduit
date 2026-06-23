# Bug Log

Auto-memory: bugs hit while working, newest first. Check here (and
`potential_skills/`) before debugging. On the 2nd occurrence of a class of bug,
promote it to `potential_skills/<domain>.md`. Format/lifecycle:
`potential_skills/README.md`.

---

### iOS 26 Liquid Glass bled the blue background into the white icon pills (light mode)
First seen: 2026-06-23 (App Store Connect + on-device; light mode only, dark looked fine)

**Pattern:** The app icon was a single flat `AppIcon.appiconset/AppIcon.png` (white
waveform pills on solid systemBlue `#0A84FF`). iOS 26 wraps every icon in the Liquid
Glass material (specular + translucency + refraction); with only one flat layer it
treats the whole image as one surface and refracts the blue up into the bottom of the
white pills — a "blue gradient down the pills" in light mode (dark mode's darker glass
hid it). NOT a color-profile shift (it's appearance-dependent → it's the glass).

**Rule:** Control the glass with a layered Icon Composer `.icon`, not a flat PNG. Now
`Conduit/AppIcon.icon` (sibling of `Assets.xcassets`; `ASSETCATALOG_COMPILER_APPICON_NAME`
stays `AppIcon`; XcodeGen auto-tags it `wrapper.icon`). The actual bleed cause is
**translucency** (the glass letting the blue background through the pills), so the only
override needed to fix light mode is group `translucency.enabled:false` (+ `specular:false`
to drop the highlight). Keep it minimal otherwise — let dark mode stay AUTOMATIC:
- Background = a single manifest `fill` (solid blue), NO dark `fill-specializations` →
  iOS auto-darkens it to the black gradient in dark mode (Apple's own Horizon example
  relies on this). Pinning a dark fill was an over-correction that forced blue-in-dark.
- Pills = one foreground layer (`Assets/pills.svg`) with `glass:true` and NO explicit
  `fill` → white in light, and the system auto-recolors them BLUE in dark with the glass
  shading (slightly darker top→bottom). That blue-on-black is the DESIRED dark look — do
  NOT force the pills white (`glass:false` + white fill) or you lose it.

Schema: github.com/dfabulich/unofficial-apple-icon-composer-json-schema.

**Verify without a device:** render the real glass with Icon Composer's bundled ictool —
`"/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool" X.icon --export-preview iOS <Default|Dark|TintedLight|TintedDark> 1024 1024 1 out.png`.
(The Xcode `xcrun ictool` is the actool variant, NOT the renderer.) Layers can be split
from a flat flat-color PNG with Pillow (mask white vs background; pills → SVG rects).

**Why it's missed:** the source PNG looks perfect, the test-sim pin (iOS 18.6) doesn't
render Liquid Glass at all, and dark mode masks the bleed — it only shows in light mode
on iOS 26 (device, or an iOS 26 sim's SpringBoard — not the icon preview in Xcode).

---

### Native CallKit call screen can't control Daily/WebRTC audio output
First seen: 2026-06-08 (M5b, native route button)

**Pattern:** Tapping the audio/route button on the SYSTEM CallKit call screen
changes `AVAudioSession.currentRoute` (the metadata) but Daily's WebRTC audio
engine keeps outputting to the previous device — the route *looks* changed while
the audio doesn't move. Mirroring the system route into Daily (observe
`routeChangeNotification` → `setPreferredAudioDevice`) does NOT fix it: it
reinforces the lying metadata, the audio still doesn't follow, and it races
Daily's own revert. The real fix (`RTCAudioSession.useManualAudio = true`) needs
control of WebRTC's audio unit, which the Daily SDK owns and doesn't expose.

**Rule:** Route control must go through the SDK's own API
(`Daily.setPreferredAudioDevice`, via `PipecatClient.updateMic`) from an **in-app
picker** — that switches audibly and stays in sync. Treat the native screen's
audio button as unreliable for SDK-managed audio; don't try to sync system→SDK.
(Apps also can't present the native call screen for outgoing calls — it's
system-controlled — so it can't be the primary surface regardless.)

**Update (M6):** This is a *Daily* limitation, not a CallKit one. `LiveKitTransport`
runs LiveKit in **manual audio** (`AudioManager.audioSession.isAutomaticConfigurationEnabled
= false` + `setEngineAvailability` gated on CallKit `didActivate`/`didDeactivate`), so on
LiveKit calls CallKit owns the `AVAudioSession` and the **native route button works**;
the in-app picker routes via `AVAudioSession` directly (`LiveKitAudioRouter`).

**Why it's missed:** `currentRoute` reports the new route, so logs say "Speaker"
while the audio is actually on AirPods — only *listening* on a device reveals it.
Research: medium.com/@tsivilko mastering-voip-audio-with-callkit-and-webrtc.

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

### A VoIP push must ALWAYS report a CallKit call — silent "ignore" kills the app
First seen: 2026-06-10 (M7 inbound device verification)

**Pattern:** `receiveCall` guarded `state == .idle` and silently returned on a
mid-call push. On device, iOS enforces that every PushKit VoIP push results in
`reportNewIncomingCall` *in that handler invocation* — a silent return gets the
app terminated, which tears down the **active** call's media (mic dot vanished,
WebRTC dead) while the CallKit UI lingered. Unit tests passed because fakes
don't model the PushKit kill.

**Rule:** Every path out of the push handler must report a call — busy means
report under the push's `call_id`, then immediately `reportCallEnded(.unanswered)`
and log a missed incoming entry; never touch the active call's state. Same
invariant family as "report even for unknown agents."

**Why it's missed:** The PushKit termination rule is invisible in the simulator
(PushKit doesn't deliver there) and in unit tests (no OS watchdog in fakes);
it only manifests as a mysterious mid-call death on hardware.

### LiveKit connect() stomped an already-arrived CallKit activation (dead first-call mic)
First seen: 2026-06-09 (reported twice on device; root-caused 2026-06-10)

**Pattern:** `LiveKitTransport.connect()` set `setEngineAvailability(.none)`
AFTER the pairing fetch. On a cold launch the fetch is slow (cold DNS/TLS), so
CallKit's audio activation landed mid-fetch: `attachAudioSession()` set the
engine `.default`, then connect's late `.none` stomped it — the room joined with
the engine forbidden, so the mic never published (no orange dot). Warm-launch
calls reordered benignly, which is why only the FIRST call after a fresh launch
failed. The same stomp would kill audio on a coordinator-driven mid-call
reconnect (`retryConnect` re-enters `connect()` while the session is active).

**Rule:** Activation (`attach`/`detach`) and `connect()` are unordered edges —
the third instance of the potential_skills/callkit.md pattern. The transport
tracks `isSessionAttached` and `connect()` asserts the CURRENT desired state
(`isSessionAttached ? .default : .none`), never an unconditional reset.

**Why it's missed:** Sim/unit tests never run LiveKit's AudioManager, and on a
warm process the pairing fetch usually wins the race. Device-only, timing-only.

### Every hangup waited out the 60s grace window — the end-call signal was never sent
First seen: 2026-06-09 (grace_expired in Railway logs after clean hangups; fixed 2026-06-10)

**Pattern:** The engine's teardown design (§2.5) reserves the human-absent grace
window for genuine drops and ends immediately on an explicit RTVI `end-call`
client message — but the app never sent one, on either transport, so every
deliberate hangup billed the bot for the full `HUMAN_ABSENT_GRACE_SECS`. Worse,
on LiveKit it *couldn't* have worked: Pipecat's LiveKit input transport re-wraps
incoming data-channel messages as OUTPUT frames, so client RTVI messages never
reach the RTVI processor at all.

**Rule:** Deliberate hangup = `Transport.disconnect()`; each adapter sends the
end signal there (Daily: `sendClientMessage("end-call")` + a 200 ms flush pause;
LiveKit: publish the RTVI client-message envelope on the data channel). The
engine listens on Daily via `on_client_message` and on LiveKit via the raw
`on_data_received` event. Verify in logs: `teardown.end_now reason=client-end-call`
(not `teardown.grace_expired`) after a clean hangup.

**Why it's missed:** Nothing fails — the call ends normally for the user and the
grace timer cleans up server-side. Only the engine logs (and the bill) show it.

### Two un-prefixed WebRTC copies in one binary — every Daily call crashed
First seen: 2026-06-10 (device probe for the SmallWebRTC transport, M9)

**Pattern:** pipecat-client-ios-small-webrtc depends on stasel/WebRTC, whose
un-prefixed `RTC*` ObjC classes duplicate the WebRTC statically linked inside
Daily.xcframework (66 classes defined in both, incl. `RTCAudioSession` and the
track types). The ObjC runtime's named-class table maps each name to ONE image,
so name-based resolution (Swift KVO's dynamic casts) got the wrong class:
`swift_dynamicCastFailure` in `DailyTransport.tracks()` on every participant
update. LiveKit never collides because its build prefixes everything (`LKRTC*`).

**Rule:** Never ship two un-prefixed WebRTC copies. Our fork
(AmirAlsad/pipecat-client-ios-small-webrtc, branch `livekit-webrtc`, pinned by
revision in project.yml) rebuilds the package against LiveKitWebRTC via a
typealias shim. After ANY transport-SDK bump, check the device launch/bundle:
`Frameworks/` must contain no `WebRTC.framework` (stasel), and a real Daily call
is the regression test. Upstream: pipecat-client-ios-small-webrtc#6.

**Why it's missed:** Links clean, sim is fine (FakeTransport), and even on
device the app launches normally — it only dies when Daily's track KVO fires
mid-call. Static check: intersect `llvm-objdump --objc-meta-data` class lists.
