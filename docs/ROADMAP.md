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
Both call directions exist in code. See [ARCHITECTURE](./ARCHITECTURE.md) and
[CORE_SYSTEMS](./CORE_SYSTEMS.md).

**The one fact that shapes this roadmap:** a large share of what's "built" is verified
only in the **simulator against fakes**. The real CallKit + **Daily** two-way audio was
device-verified (M3/M5), the **LiveKit** call path (pairing connect, two-way
audio, the native route button, reconnection — against the deployed reference
engine) in June 2026, and the **inbound VoIP-push round-trip** (cold ring through
redeploy survival, LiveKit agent) days later. Not yet proven on hardware:
**interruption/ducking** audio, `setOnHold` for a real incoming phone call, and
finalized spoken-state ducking. You cannot responsibly build on a foundation that
hasn't rung a real phone — so the roadmap leads with closing that debt.

## Guiding principles (the constraints that pick priorities)

- **No backend of ours, ever.** No accounts, no token service, no analytics, no
  Firebase. Credentials are the user's and live in the Keychain. This is why the
  developer on-ramp (M8) ships *runnable example* code, never a hosted service.
- **The testability spine holds.** Every new external boundary gets a protocol seam +
  an in-app fake, so logic verifies at sim speed and only genuine audio/CallKit/Push
  behavior needs a device.
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
  with a quiet local notification, busy pushes report-then-end (silently ignoring a
  VoIP push gets the app killed — `bugs.md`), and rings surviving a backend redeploy
  (volume-backed registry). The remaining gaps closed days later: the answer path
  over a **Daily** agent (cold ring → answer → echo → immediate end-call teardown),
  unknown-agent graceful end (brief ring, self-ends, app healthy), registration at
  toggle-save (no relaunch), and **ring-status receipts** (`answered` /
  `suppressed_by_focus` observed live on both transports).
- **Interruptions & ducking, real audio** — Siri mid-call (pause + clean resume), an
  incoming PSTN call (yield the route), and **nav/GPS prompts ducking/mixing over the
  call** in the car (AirPods / CarPlay). Verify on both transports.
- **`setOnHold` for a real incoming phone call** — the flagged follow-up; the
  interruption observer is its foundation. Build + verify hold/resume.
- **Finalize spoken-state ducking** under the CallKit-owned session — the announcer must
  *mix with*, never deactivate, the session.

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
- **A runnable reference backend** (in-repo `examples/` or a sibling repo) — a minimal
  Pipecat agent + a pairing/token endpoint + an inbound-push sender, implementing
  [CONNECTION_CONTRACT](./CONNECTION_CONTRACT.md) and [INBOUND_CALLS](./INBOUND_CALLS.md).
  Turns the contract docs into code a developer can run. **Not "our backend"** — sample
  code they own and host. (Also the tool M7 needs to verify inbound.)
- **QR / deep-link pairing** — scan a code your server prints, or open a `conduit://…`
  link, to pre-fill agent name + transport + pairing endpoint + key. Removes the most
  error-prone manual typing. *(Named fast-follow.)*
- **Connection diagnostics** — a real "Test connection" that reports each step (resolve
  pairing → got room/token → transport negotiated → bot-ready) and maps the coordinator's
  failure distinctions (`badToken` / `transportError` / `lostConnection`) to actionable
  messages, surfaced in Add/Edit Agent.
- **Better failure copy** in-call and in Recents — *why* a call failed, in human terms.

**Verification:** pairing/QR parsing + diagnostics logic unit-test in the sim; the
example backend is runnable + documented; live connect is device-only.

**Why now:** with M7 proving the pipe works, getting agents *connected* becomes the
bottleneck. This is what makes Conduit adoptable.

---

## M9 — Fully self-hosted transport (SmallWebRTC)

**Goal:** run Conduit against your own WebRTC server with **no Daily/LiveKit cloud
account** — the purest expression of "you own everything."

**Scope:** a **SmallWebRTC** transport behind the existing `Transport` protocol (the
Pipecat client supports it), reusing the connect-gate and audio-ownership patterns
proven for Daily/LiveKit; the connection contract extended for its signaling shape; the
M8 reference backend gains a SmallWebRTC variant.

**Verification:** connect-gate logic in the sim; audio device-only (same posture as the
other transports).

**Why now:** removes the last third-party cloud dependency and completes the self-host
story the whole app is premised on. Additive transport surface, so it sits after the
on-ramp rather than blocking it.

---

## M10 — Hands-free reach (the car vision)

**Goal:** deliver the original "take it in the car, hands-free" promise beyond a manual
in-app tap.

**Scope:**
- **"Hey Siri, call &lt;agent&gt;"** via App Intents / Assistant intents, leaning on the
  synthetic contact handle already laid for Siri/CallKit matching — lock-screen and
  CarPlay voice dialing.
- **CarPlay dashboard app** + its entitlement — the call list / recents on the car
  screen. *(Named fast-follow; needs the CarPlay entitlement.)*
- **Favorites / quick-dial** — a Favorites surface, a widget, or Control Center for the
  agents you call most.

**Verification:** intent donation + parsing in the sim; Siri/CarPlay dialing is
device/CarPlay-only.

**Why now:** the in-car, hands-free use case is the reason Conduit rides CallKit at all.
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
- **Docs discipline** — update the relevant `docs/` file with each architectural change.
- **The hard constraints** — no backend / Firebase / analytics; secrets only in the
  Keychain, never in a log, a contact, or source control.
- **Test-sim pin** — iPhone 16 / iOS 18.6 (the iOS 26 sim's accessibility subsystem is
  broken).

## Deferred / explicitly not doing

- **Agent design or iteration** — STT/LLM/TTS/voice/memory are the user's, out of scope.
- **Cross-device persistent memory** — lives in the agent, not the app.
- **A "warm inbound" backend-free variant** (signaling an already-running app over the
  live transport) — VoIP push is the chosen path; revisit only if the entitlement blocks.
- **Multi-call / conferencing** — one call at a time, by design.
- **Any first-party backend, accounts, or analytics** — a permanent constraint, not a gap.
