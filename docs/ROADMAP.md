# Roadmap

Where Conduit goes next, and **why in this order**. The north star is unchanged:
let a developer **call — and be called by — a voice agent they already run**, as a
native, hands-free phone call. Everything here serves that one sentence.

This is a living document. The sequence is a recommendation, not a contract; reorder
freely. What it is *not* is a backlog dump — each milestone states a goal, the scope,
how it gets verified, and why it earns its slot now.

## Where we are

Built through **M6** plus post-M6 follow-ons: the call state machine, **Daily** and
**LiveKit** transports, the CallKit + audio-session seam, Keychain, permission-free
Add-to-Contacts, reconnection + spoken state, Recents swipe-to-delete, the
audio-interruption seam, and the **full inbound (agent-initiated) call plumbing**.
Both call directions exist in code — and **M8's on-ramp is built** (QR/deep-link
pairing, staged connection diagnostics, persisted failure reasons, decluttered
in-app copy). The call engine (state machine, CallKit, PushKit, the Daily and
LiveKit adapters) lives in the `ConduitCallEngine` Swift package, consumed by version
from `github.com/AmirAlsad/ConduitCallEngine` (0.2.x). The adoption of engine 0.2 —
pre-connect while ringing, ring timeouts and cancels, call-control
signals to the agent, engine-driven cues, a join deadline, the SDK bumps — is built,
unit-tested, and was **run in part on a device on 2026-11-12** (iPhone 17, iOS 27.0,
Daily, LiveKit and SmallWebRTC); what passed and what was not run is in the Results
of [DEVICE_VERIFICATION](./DEVICE_VERIFICATION.md).
Call hold is **not** shipped: the engine's hold is an experimental opt-in the app
leaves off, so a phone call ends the call (see "Hold for a real phone call" below).
See [ARCHITECTURE](./ARCHITECTURE.md) and [CORE_SYSTEMS](./CORE_SYSTEMS.md).

**History, in short.** M0 foundation (protocol seams and fakes, SwiftData models,
`AppEnvironment`); M1 the call state machine, reconnection and spoken state; M2 the
Daily transport; M3 the CallKit and audio-session seam; WS-4 the Keychain and the
permission-free Add to Contacts; WS-5 all six feature modules; M5 the device-verified
realistic target; M6 the LiveKit transport; then swipe-to-delete in Recents, the
audio-interruption seam, inbound calls with ring-status receipts and registration on
save (June 2026); M8 the developer on-ramp; M9 SmallWebRTC; M10 Siri dialing, layers
1–2; the extraction of the call engine into the `ConduitCallEngine` package (November
2026, device-verified on 0.1.1); and the engine 0.2 adoption: SDK bumps, engine cue
events driving the spoken cues, every missed ring recorded with its reason,
call-control signals, pre-connect while ringing, `call-answered`, the 30 s join
deadline, the explicit microphone request, `push_features` at registration, the
rebuilt SmallWebRTC adapter, the system speech session and the route-aware ringback,
and the DEBUG call trace and Cue Lab. The sections below have the detail.

**The one fact that shapes this roadmap:** a large share of what's "built" is verified
only in the **simulator against fakes**. The real CallKit + **Daily** two-way audio was
device-verified (M3/M5), the **LiveKit** call path (pairing connect, two-way
audio, the native route button, reconnection — against the deployed reference
engine) in June 2026, and the **inbound VoIP-push round-trip** (cold ring through
redeploy survival, LiveKit agent) days later; the engine 0.2 behaviour (pre-connect,
ring timeouts and cancels, the connect sequence, the route-aware cues) on
2026-11-12. Not yet proven on hardware: a phone call ending the call on the final
build, **interruption/ducking** audio (Siri, navigation prompts), Focus-filtered
rings on current iOS, and CarPlay. You cannot responsibly build on a foundation that
hasn't rung a real phone — so the roadmap leads with closing that debt.

## Guiding principles (the constraints that pick priorities)

- **No backend of ours, ever.** No accounts, no token service, no analytics, no
  Firebase. Credentials are the user's and live in the Keychain. This is why the
  developer on-ramp (M8) ships *runnable example* code, never a hosted service.
- **The testability spine holds.** Every new external boundary gets a protocol seam +
  a fake (the engine's in the package's `ConduitCallEngineTesting` product, the
  app's in the app target), so logic verifies at sim speed and only genuine
  audio/CallKit/Push behavior needs a device.
- **Prove, then grow.** A capability isn't "done" until it works on hardware. New
  surface area waits behind verification of what it builds on.
- **Self-built / self-signed.** Each developer builds Conduit under their own Apple
  team and holds their own APNs key. This is what keeps "no backend of ours" true for
  inbound — and it's also why broad public App Store distribution is out of scope
  (see M11).

---

## M7 — Prove it on hardware (verification + hardening)

**Goal:** every capability shipped through the M6 follow-ons is verified on a physical
device, not just in the sim against fakes. This milestone is mostly hardware testing +
bug-fix, not new surface.

**Scope:**
- **LiveKit path end-to-end on device** ✅ — connect, two-way audio, the native
  call-screen route button actually moving audio (LiveKit's manual-audio advantage
  over Daily), and reconnection, device-verified June 2026 against the deployed
  reference engine over pairing. Still to check: the in-app picker on LiveKit.
- **Inbound VoIP-push round-trip on device** ✅ — device-verified June 2026 against
  the deployed reference engine (LiveKit agent): cold ring → answer → two-way audio,
  decline → Recents, inline credentials, Focus/DND-filtered rings logged as missed
  with a quiet local notification (on the iOS of June 2026; on iOS 27.0 in November
  Do Not Disturb did not filter rings, so that path is unexercised there), busy pushes report-then-end (silently ignoring a
  VoIP push gets the app killed — `bugs.md`), and rings surviving a backend redeploy
  (volume-backed registry). The remaining gaps closed days later: the answer path
  over a **Daily** agent (cold ring → answer → echo → immediate end-call teardown),
  unknown-agent graceful end (brief ring, self-ends, app healthy), registration at
  toggle-save (no relaunch), and **ring-status receipts** (`answered` /
  `suppressed_by_focus` observed live on both transports).
- **Interruptions & ducking, real audio** — Siri mid-call (pause + clean resume), an
  incoming PSTN call (yield the route), and **nav/GPS prompts ducking/mixing over the
  call** in the car (AirPods / CarPlay). Verify on both transports.
- **Hold for a real phone call — open follow-up; cut from the release.** Today a
  phone call the user accepts or places ends the Conduit call (the engine's
  `supportsHolding` is off by default and the app leaves it off; the in-call Hold
  control is gone). Holding was built and device-tested (iPhone 17, iOS 27.0, Daily
  and LiveKit) and does not work yet:
  - In-app hold and resume with no other call restored two-way audio on both
    transports, every time it was tried.
  - With a real phone call: iOS held the engine's call; when the phone call ended
    the engine resumed it and CallKit reported `didActivate`; the session read
    `PlayAndRecord` / `VoiceChat`; and no audio returned in either direction. On
    LiveKit, `setEngineAvailability(.default)` failed with `LiveKitError` code 801,
    "Audio engine returned error code: -4010", on every attempt for at least six
    seconds (the engine's three re-attaches and the experimental restarts all failed
    the same way); once CallKit's activation came 5.4 s after the resume. On Daily
    no error surfaced and audio was simply absent; a second in-app hold/resume and a
    route change did not help. iOS never delivered an interruption-ended
    notification in any run.
  - Observations from **one run each**, not conclusions: on Daily, experimental
    candidate C (leave without the end-call signal, release the client, rejoin the
    same room on a fresh client) **did** restore two-way audio once (the user heard
    "Disconnected", then "Connected", then the echo); so the audio hardware is
    available again after the phone call and what fails to restart is each SDK's
    existing audio stack, and a rejoin is a working recovery on Daily. On LiveKit
    every candidate (restart the audio engine at once; after a pause with retries;
    tell WebRTC's audio session it was activated, then restart) failed with the same
    -4010; nothing is known to work there.
  - **Open question:** on both transports, after the phone call ended, the system
    call screen still showed the call as on hold while the engine and the app
    reported it not held. Untraced; candidates are CallKit holding the call again
    without delivering an action, the engine marking a resume CallKit did not
    complete, or a stale system UI. It matters: if CallKit really still holds the
    call, that could be why LiveKit's audio engine cannot start.
  - **Next to try:** the two session-level experiments that were never run:
    re-applying the session's category and mode (`playAndRecord` / `voiceChat`)
    before the attach (E-A), and additionally activating the session explicitly
    (`setActive(true)`, E-B, against the rule that CallKit owns activation). Then
    trace the stale held state, and decide whether Daily's rejoin is acceptable as
    the recovery there. The candidates, the DEBUG picker that chose them and their
    tests are on the `hold-recovery-experiments` branch in both repos (Conduit and
    ConduitCallEngine); `main` keeps only the attach retry, LiveKit's refused-start
    report, the activation re-check while another call is listed, and the session
    log at the attach after an interruption.
- **Spoken cues under the CallKit-owned session** ✅ — the announcer speaks through
  the system's own speech session and never touches the call's session; the ringback
  is chosen by route. Heard on Daily and LiveKit, 2026-11-12. Still open: ducking of
  other audio (navigation prompts) over a call, and the cues in the last retry phase
  of a long LiveKit outage (not recorded).

**Verification:** Layer 2/3, manual, on device. Output a reusable device-verification
checklist (extend [AGENT_WORKFLOW](./AGENT_WORKFLOW.md) or add a test matrix).

**Why now:** converts "built" into "provably works." Everything downstream assumes the
pipe is real.

> **Sequencing note:** verifying the inbound path in M7 needs a server that can send a
> VoIP push — which is exactly the reference push-sender from M8. Pull that minimal
> sliver forward; the rest of M8 follows.

---

## M8 — Developer on-ramp (zero-to-call, fast)

**Goal:** a developer with their own agent goes from nothing to a working two-way call
in minutes — and can self-diagnose when it doesn't connect. This is the highest-leverage
work for the **developers** in the core purpose: today the friction isn't the app, it's
standing up a backend to pair through.

**Scope:**
- **A runnable reference backend** ✅ — `example-backend/`: Pipecat agents + the
  pairing/credentials endpoints + the inbound-push stack, implementing
  [CONNECTION_CONTRACT](./CONNECTION_CONTRACT.md) and [INBOUND_CALLS](./INBOUND_CALLS.md).
  **Not "our backend"** — sample code they own and host.
- **QR / deep-link pairing** ✅ — `conduit://add-agent` links (versioned, validated
  `DeepLinkParser`) pre-fill the whole Add Agent form; a link matching an existing
  agent's pairing endpoint opens **Edit** (re-scan after key rotation, no duplicates),
  and a key-less link never wipes a stored key. `scripts/pair.py` prints the link + a
  terminal QR (key embedded by default, `--no-key` opt-out — the link is then a secret;
  documented). Verified in the sim via `simctl openurl`; Camera-scan is the device pass.
- **Connection diagnostics** ✅ — "Test connection" is a staged checklist (pairing
  endpoint reached → credentials minted → transport connected → agent ready) with a
  granular message on the failing step (401 vs HTTP n vs malformed response vs
  room-token rejection vs bot-never-ready).
- **Better failure copy** ✅ — the failure reason persists into the call log
  (`CallLogEntry.failureReasonRaw`, lightweight migration): Recents/Agent Detail read
  "Failed — authentication", and the failed-call screen adds an actionable hint.
- Alongside: the app's forms **decluttered** to one-line footers + "Learn more" links;
  the long-form explanations moved to the published `using-conduit.md`.

**Verification:** parser/diagnostics/VM logic unit-tested in the sim (136 tests);
deep-link flow verified live in the sim. Device pass outstanding: Camera-scan QR →
prefilled sheet, staged diagnostics against the deployed engine, and a migration
sanity check over existing on-device history.

**Why now:** with M7 proving the pipe works, getting agents *connected* becomes the
bottleneck. This is what makes Conduit adoptable.

---

## M9 — Fully self-hosted transport (SmallWebRTC) ✅ *(built & device-verified, June 2026)*

**Goal:** run Conduit against your own WebRTC server with **no Daily/LiveKit cloud
account** — the purest expression of "you own everything."

**Shipped:** `TransportKind.smallwebrtc` + `PipecatSmallWebRTCTransport` (mirrors the
Daily adapter; pairing returns the offer URL + a short-lived bearer as
`connection.room_url`/`token`, so `PairingClient` needed zero changes); the engine
gained `POST/PATCH /webrtc/{agent_id}/offer` with **in-process bots** (the offer is the
rendezvous — no room, no subprocess; dropped peer ⇒ immediate `end_now`); contract +
quickstart document the offer leg and the zero-cloud LAN path (`pair.py --transport
smallwebrtc`). **Scope is LAN / self-hosted-with-UDP** — media is UDP, so no Railway.

**The collision war story:** the stock package depends on stasel/WebRTC, whose
un-prefixed `RTC*` ObjC classes duplicate Daily's statically-linked WebRTC — on device
every Daily call crashed (`swift_dynamicCastFailure` in `DailyTransport.tracks()` KVO;
66 classes defined in both images). Fix: our fork
[`AmirAlsad/pipecat-client-ios-small-webrtc@livekit-webrtc`](https://github.com/AmirAlsad/pipecat-client-ios-small-webrtc)
rebuilds the package against LiveKit's `LKRTC*`-prefixed WebRTC (a typealias shim —
SmallWebRTC and LiveKit now share one prefixed copy; Daily keeps the only un-prefixed
one). Reported upstream as
[pipecat-client-ios-small-webrtc#6](https://github.com/pipecat-ai/pipecat-client-ios-small-webrtc/issues/6);
revisit the fork if upstream adopts a prefixed flavor.

**Device-verified** (iPhone over hotspot LAN → Mac engine): pairing → offer/answer →
trickle ICE → two-way audio on the loopback agent; clean `end-call` via the standard
RTVI path; immediate bot teardown; Daily + LiveKit regression calls green in the same
binary. Found along the way: iOS's **local-network permission** gates the first LAN
connection (`NSLocalNetworkUsageDescription` added); Test Connection briefly grabs the
mic on this transport (the SDK starts its audio unit on connect — known wart).
Unverified leftovers: native route button behavior on SmallWebRTC calls, mid-call
Wi-Fi-drop reconnect (re-pairs to a fresh bot — context resets by design).

---

## M10 — Hands-free reach (the car vision) — voice dialing built, device pass in progress

**Goal:** deliver the original "take it in the car, hands-free" promise beyond a manual
in-app tap. No CarPlay entitlements, ever (user decision).

**Shipped — three-layer Siri dialing, one funnel:**
1. **App Intents App Shortcut** — "Call \<agent\> on Conduit" (`CallAgentIntent` +
   `AgentEntity` backed by the tiered `AgentNameMatcher`). `openAppWhenRun = true` is
   load-bearing: CallKit rejects `CXStartCallAction` from a background intent, so
   `perform()` only parks the id on `AppEnvironment.pendingSiriCall`, consumed by
   `RootTabView` once the scene is `.active`. Vocabulary refreshes at launch + every
   agent save/delete. Because it's an App Intent, **"call my agent" composes into any
   user Shortcut or Automation** (e.g. car-Bluetooth-connected → call agent) — document
   and extend this (more actions: end call, mute?) as a follow-up.
2. **SiriKit `INStartCallIntent`** (in-app handling, no extension) — covers "call
   \<agent\>" without the app name and the calling domain's lock-screen/CarPlay
   special-casing until iOS 27. `INPerson` handles reuse the contact-mirror synthetic
   email; resolution feeds the same funnel.
3. **iOS 27 `.phone.startCall` schema** — deferred until the Xcode 27 beta SDK is
   installed; `CallAgentIntent`'s type/parameter names are frozen so the schema
   conformance upgrades it in place (contingency: a second schema-conforming intent).

**Device findings (June 2026, dev-signed build):** Settings' "Use with Siri Requests"
defaulted OFF until we added the one-time `INPreferences.requestSiriAuthorization`
prompt. **Reliable:** warm + unlocked dialing on both layers, the Shortcuts-app
action, spoken disambiguation. **Found + fixed:** the in-app SiriKit continuation
dropped the agent id (iOS doesn't reliably attach the INInteraction — the id now rides
the activity's userInfo). **Found + documented:** the no-app-name phrase anchors on
**Contacts** — agents without the Add-to-Contacts mirror are invisible to Siri's
calling domain (it gives up silently or snaps to the nearest real contact), which is
the contact mirror's whole Siri story working as designed. **The bare-phrase resolution chain (debugged on device, now verified working):**
"Hey Siri, call \<agent\>" rides Siri's calling domain, which resolves contacts
*before* dispatching to any app — three links had to hold: (1) the **contact mirror**
anchors the spoken name (agents without Add-to-Contacts are invisible — Siri gives up
or snaps to the nearest real contact); (2) **interaction donations carrying
`INPerson.contactIdentifier`** teach Siri the card is callable via Conduit (without
the identifier Siri matched the card but refused with "add contact information" —
the card deliberately has no phone number); (3) the **multiple-scenes declaration**
in Info.plist, without which `application(_:handlerFor:)` is never invoked. With all
three in place, bare-name dialing works, including rename → re-recognition. Also
found + fixed: a never-consumed locked-phone dial request resurfacing later as a
phantom call (`PendingSiriCall` now expires after 30 s). **Lock-screen dialing works
but requires unlock** — inherent to `.continueInApp` opening the app; candidates for
a no-unlock path are the Intents-extension architecture (Telegram's shape; untested
whether it avoids the unlock) and the iOS 27 schema, which is the designed answer.
Outstanding: in-car steering-wheel test (next drive), layer 3 (Xcode 27 SDK).

**Still open in M10:** CarPlay dashboard app (needs the entitlement — out), Favorites /
quick-dial surface, widget/Control Center.
Once the call path is proven (M7) and agents connect easily (M8), this is the experience
payoff — and the heavier entitlement/device lift earns it a later slot.

---

## M11 — Polish, onboarding & distribution readiness

**Goal:** first-run and everyday polish on a stable feature set, plus readiness to share
the build within your own team.

**Scope:** a guided cold-start onboarding (the empty states already funnel to "add your
first agent" — extend to a guided first-pairing), Settings expansion, a full
accessibility / Dynamic Type pass (`swiftui-pro`), consistent app-wide
error/empty/loading states, and a self-built **distribution checklist** (signing,
entitlements, TestFlight within your team).

> **Honest distribution note.** The self-built / self-signed APNs model that keeps "no
> backend of ours" true for inbound also means **broad public App Store distribution is
> out of scope** — each user must build under their own team. Distribution stays "your
> own team / TestFlight," unless the inbound architecture is deliberately revisited.

**Why now:** polish is continuous, but crystallizes last so it lands on a settled
surface rather than a moving one.

---

## Cross-cutting threads (always on)

- **Testability spine** — protocol seam + fake for every new boundary.
- **Pinned dependencies** — SDK versions come from the tracked root
  `Package.resolved`; bump them deliberately and re-run the device checks.
- **Docs discipline** — update the relevant `docs/` file with each architectural change.
- **The hard constraints** — no backend / Firebase / analytics; secrets only in the
  Keychain, never in a log, a contact, or source control.
- **Test-sim pin** — CI runs iPhone 16 / iOS 18.6 (the iOS 26 sim's accessibility
  subsystem is broken); a Mac that can't install an iOS 18 runtime uses iPhone 17 /
  iOS 27.2 locally, where XCUITest queries work.

## Follow-ups from the November 2026 device runs

Each item below says where it stands after the engine 0.2 adoption and the
2026-11-12 device session ([DEVICE_VERIFICATION](./DEVICE_VERIFICATION.md), Results).

- **Spoken cues on Daily** — on the 0.1.1 run "Connected", "Disconnected" and
  "Retrying connection" were audible on LiveKit calls but not during Daily calls, and
  went silent in the last retry phase of a LiveKit outage. **Fixed for Daily:** the
  DEBUG Cue Lab showed that speech in the app's audio session was inaudible during a
  Daily call while the system's own speech session was heard, so the announcer now
  uses it; the cues were heard on Daily and LiveKit on 2026-11-12. The last retry
  phase of a long LiveKit outage was not recorded.
- **Call hold** — placing or taking a cellular call ended the Conduit call. **Still
  so, by decision:** holding was built and tested on a device, but audio did not come
  back after a real phone call, so it is off (see "Hold for a real phone call" above).
  To confirm on each transport: accepting a phone call ends the call cleanly
  (DEVICE_VERIFICATION H1; not run on the final build).
- **Focus-filtered rings** — re-check on device when iOS filters them again; the path is
  unit-tested but was not exercised on iOS 27.0. **Unchanged.**
- **SiriKit "Call <agent>"** — re-run with an agent that is in Contacts (unlocked and
  from the lock screen). **Unchanged.**
- **Test Connection on LiveKit** left the agent waiting out its grace window (no
  end-call signal was sent that early). **Fixed:** `LiveKitTransport.disconnect()`
  now sends the end-call signal whenever the room is not already leaving, including
  while a connect is in flight (package issue #22); on 2026-11-12 the agent received
  end-call and tore down within a fraction of a second.
- **The `live` reference agent's keys** — the Groq key in the local engine config is
  dead; device runs used the loopback echo agent. **Unchanged** (environment, not code).

### Open items created by the 0.2 adoption

- **The rest of the device session.** The 0.2.0 sheet in
  [DEVICE_VERIFICATION](./DEVICE_VERIFICATION.md) ran in part on 2026-11-12. Not run:
  a phone call ending the call on the final build (H1 to H4), Focus-filtered rings,
  SiriKit "Call <agent>" with a contact, an incoming call on AirPods, the tone-agent
  leak checks, the join deadline, CarPlay and wired routes, and the other rows left
  empty there.
- **The spoken-cue mechanism: decided (November 2026).** Speech goes through the
  system's own speech session, the ringback is chosen by route (system sound on the
  phone's own outputs, an audio player on headset-type ones). Open: CarPlay and wired
  routes, and the last retry phase of a long LiveKit outage.
- **Daily joining during a ring: decided (November 2026).** The DEBUG picker's three
  strategies were run on an iPhone 17 (iOS 27.0, locked, app not running). D1 (default
  subscriptions during the ring) failed: no agent audio for the whole call, and the
  route flipped between speaker and earpiece four times in 2.5 s. D2 (agent audio
  unsubscribed from before the join until the first attach) passed: a silent 20 s
  ring, clean agent audio at the answer, route settled within about 0.3 s, also with a
  cold launch by the push. D3 (staged) showed no advantage. The package now joins
  Daily during a `media` ring with D2's method and the picker is gone. Open: other
  devices, Bluetooth/CarPlay routes, and rings longer than 20 s.
- **Incoming calls ready when the user picks up.** Answered calls no longer wait for
  the outgoing minimum or play the ringback (heard after an answer "as though I am the
  one calling"); the reference backend asks for pre-connect by default and starts the
  agent before it rings. On 2026-11-12, on Daily and LiveKit, a ring joined during
  the ring and answered was silent at the answer with the echo at once, and one
  answered before the agent was there played "Connected" when it arrived
  (DEVICE_VERIFICATION, section W; the pairing-mode and slow-agent rows not run).
- **Same room on reconnect.** Today an engine-level reconnect asks the pairing
  endpoint for credentials again, and a server that makes a new room each time gives
  the user a fresh agent session, so the conversation starts over. Resuming the same
  conversation needs the app to tell the server which call a request belongs to (the
  engine's connect request already carries the purpose and, for incoming calls, the
  call id) and the server to hand back the same room while its agent is still there.
- **Separate pairing and admin keys** in the reference server. Today the key in a
  pairing link is also the server's admin key (`/admin/ring`, `/admin/disconnect`), so
  anyone holding a pairing link can ring the user and end calls. Give pairing its own
  key, so a pairing link carries no admin rights.
- **SmallWebRTC on hold and signals.** Its SDK exposes no playout control, so with the
  engine's hold (off today) a held SmallWebRTC call would be silent only if the agent
  honoured `call-held`, and the SDK reports
  nothing past the data channel's hand-off, so a signal's delivery cannot be
  confirmed. It also cannot join while ringing.
- **Package issue #13, deferred items.**
  [ConduitCallEngine#13](https://github.com/AmirAlsad/ConduitCallEngine/issues/13):
  in-app answer and decline, provider icon / ringtone / handle type, a configurable
  reconnect policy, a CallKit call-id accessor, and host-owned PushKit registration.
  The engine does not offer these today. (The hands-free policy is now configurable:
  `CallEngineConfiguration.defaultsToSpeaker`, off in the package and in Conduit.)

## Deferred / explicitly not doing

- **Agent design or iteration** — STT/LLM/TTS/voice/memory are the user's, out of scope.
- **Cross-device persistent memory** — lives in the agent, not the app.
- **A "warm inbound" backend-free variant** (signaling an already-running app over the
  live transport) — VoIP push is the chosen path; revisit only if the entitlement blocks.
- **Multi-call / conferencing** — one call at a time, by design.
- **Any first-party backend, accounts, or analytics** — a permanent constraint, not a gap.
