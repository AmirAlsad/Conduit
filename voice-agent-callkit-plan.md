# Bring-Your-Own-Agent Voice Client — Implementation Plan

*A native iOS app that turns any voice agent you already run into a hands-free phone call you can take in the car. No CarPlay entitlement, no per-minute carrier cost, no backend of ours.*

## The vision

You bring the brain; the app supplies the ears, the mouth, and the car. Someone who already runs a voice agent (Pipecat, LiveKit, or anything that speaks a supported WebRTC transport) points the app at it, and from then on talking to that agent is just placing a call — initiated from the phone, answered through the car's own audio system over Bluetooth. The agent owns everything that makes it *its* agent: the model, the voice, the persona, the memory. The app stays a thin, faithful audio pipe.

The guiding ethos is the ntfy one: subscribe to your own endpoint, point your own server at it, no accounts, no cost, it just works. Everything below bends toward keeping that simplicity intact — the connection is bring-your-own, and there is no service of ours sitting in the middle.

## Why a call, not a CarPlay app

The instinct was a CarPlay dashboard app under the new voice-conversational entitlement. The call-based approach wins for the build, and the reasoning shapes the whole design:

- **No gatekept entitlement.** Riding CallKit (the framework that lets VoIP apps behave like the native Phone app) means calls route through CarPlay and Bluetooth automatically, with nothing to apply for and no Apple approval queue.
- **Works in every car, not just CarPlay ones.** A call comes through any car that pairs over Bluetooth.
- **Full audio quality.** Because the call travels over WebRTC rather than the cellular voice network, you get wideband audio instead of the 8 kHz "phone voice," and you avoid PSTN per-minute charges entirely.
- **It's the most honest expression of the idea.** "Call your agent" is agent-agnostic by nature. The dumb-pipe client *is* the bring-your-own-agent thesis.

The CarPlay voice-conversational entitlement isn't abandoned — it's deferred to a later, polished, on-dashboard version. That approval is slow, so the request can run in the background, but it is not on the critical path.

## Architecture at a glance

Three pieces, conceptually:

1. **The call layer (CallKit).** Presents the agent session as a native call — the system call UI, Bluetooth/CarPlay audio routing, mute/end controls, lock-screen behavior. CallKit owns the audio session; the app reports the call and hands control to the system.
2. **The transport layer (WebRTC, via the Pipecat iOS client).** Carries real-time audio to and from the agent, with turn detection and interruption handling provided by the framework. Transports are swappable: Daily and LiveKit in this build, SmallWebRTC later for the self-host case.
3. **The agent (theirs, not ours).** Whatever the user runs. It does STT, the LLM, TTS, voice selection, and any memory. The app neither knows nor cares which models are behind it.

The one genuinely fiddly seam is where CallKit and WebRTC meet: the system call lifecycle has to own activation of the audio session, and the WebRTC media has to attach to it at the right moment rather than grabbing the microphone on its own. Getting that handshake right is most of the real work; the rest is wiring.

## The app, modeled on Phone

The app borrows its structure from iOS's own Phone app, because the core verb is literally "call" — users arrive with the muscle memory already loaded. Three tabs:

**Recents (home).** A call log, most-recent first, since calling is overwhelmingly a "redial the last one" behavior. Native swipe-to-delete on rows (and a clear-all); deleting a log entry removes history, not the agent. Failed calls — bad token, agent offline — appear in red like a missed call, so a failure is legible after the fact. The cold-start empty state is load-bearing: a brand-new user's Recents is empty, so it funnels straight to "add your first agent."

**Contacts.** The list of agents, each treated as a contact. Each row has a quick-call button on the right for one-tap dialing; tapping the row itself opens Agent Detail. New agents are added here.

**Settings.** Deliberately sparse: an About section (connection-spec/help link, report a bug, version) and the global always-listening vs. push-to-talk toggle. Every toggle and option carries a plain-language explanation in the native grouped-form footer — these are read at setup time, at a desk, never mid-drive.

**Agent Detail (the contact card).** Tapping an agent opens a card modeled on the Phone app's contact view: name, photo, description, a connection summary, a prominent Call button, and the per-agent slice of the call log below. "Thin" here isn't a deficiency — a name, a photo, a Call button, and recent calls *is* the native contact pattern.

**Add / Edit agent (the sheet).** This is the bring-your-own configuration surface. Name; description (shown as the row's second line, like a contact label); optional avatar with an initials/monogram fallback; and the connection — pairing-first (transport + pairing endpoint + API key, the usual Pipecat/LiveKit setup) with a direct room URL as the advanced alternative — plus a **test-connection** action that does a quick connect-and-disconnect so a stale token fails at the desk, not on the highway. Adding the agent to Contacts is a separate, permission-free action on the agent's detail screen (the system Add-Contact sheet) rather than a toggle here: it lets you say "Hey Siri, call Jarvis," shows the agent in your Contacts, and puts its name + photo on the call screen.

Borrow the *structure* of Phone, but don't pixel-clone Apple's UI, and lean into the genuine "this is a VoIP calling app" framing — both because Apple is touchy about apps imitating system apps and because "contacts you actually call over VoIP" is what keeps the CallKit usage defensible. No Favorites tab: with a handful of agents, Contacts is effectively your favorites and Recents-first already does the redial job.

## The contact model and the system-contact mirror

In-app records are the source of truth, and the token lives in the **Keychain** — never in a contact, since contacts sync to iCloud and are user-visible. On top of that, each agent can optionally mirror its *display identity* (name, photo, a matchable handle) into the system address book, controlled by the per-agent toggle in the add/edit sheet.

Why mirror at all: the system call UI (lock screen, Dynamic Island, CarPlay) shows a saved contact's photo and name when the call's handle matches that contact — the same way a friend's photo appears when they call. So the mirror is what gets the agent's avatar and name onto the screens that show while driving (the app's own name on the call already travels via the call handle; the photo is what the mirror buys you).

The handle: agents have no real email or phone number, so mint a stable synthetic email per agent — namespaced, on a reserved `.invalid`-style domain so it can't be mistaken for a real address — store it as the agent's handle, set it on the mirrored contact's email field, and use that same email-type handle when placing the call. Email type is chosen deliberately over "generic": a generic handle makes Siri read out the raw alphanumeric ID even when a proper caller name is set, and the email type sidesteps that while still giving clean contact-matching.

Lifecycle to own: writing contacts triggers a Contacts-permission prompt (asked only when the toggle is flipped), and the mirror must update on edit and be removed on delete — with the known caveat that app-created contacts can linger in the address book after the app is deleted. The mirror is in scope for the build; reliable "Hey Siri, call Jarvis" from a locked screen is a fast-follow, since the mirror reliably delivers the name/photo/Contacts presence but the locked-Siri dialing path is finicky.

## The in-call screen

Two surfaces, and the split is the whole point. While the phone is locked or screen-off — the case that matters in the car — the *system* CallKit UI owns the call: lock-screen controls, the route picker, mute/end, the CarPlay call display. You don't design that and can't replicate it (it's private, and imitating it draws App Review scrutiny).

The one screen you build is the in-app foreground screen, shown only when the app is open during a call — exactly the WhatsApp/Zoom pattern, where the app shows its own in-call screen and the system takes over on lock. That handoff is a decade-old convention, not a cheap seam. The foreground screen also does the one thing the system screen *can't*: show whether the agent is listening, thinking, or speaking. The spec:

- A red **End** button (fires the end-call action) and a **Mute** toggle.
- A **push-to-talk button**, present only when push-to-talk mode is enabled — held down to speak.
- A native **route picker** (`AVRoutePickerView`) for switching between earpiece, speaker, and any connected Bluetooth device including the car — the system component, so no hand-drawn route menu and no enumerating devices yourself.
- The agent **avatar and name**, plus a **status line**: connecting / connected / reconnecting / a running call timer.
- A **listening/speaking indicator** — a subtle glow around the avatar when the agent is speaking. This is the single purposeful piece of custom UI, justified because in a voice-only product the user otherwise has no signal they were heard.
- On call start, default the route to speaker or the connected Bluetooth/car route — never the earpiece, since this is always a hands-free call.

What CallKit gives for free, with nothing to build: the Dynamic Island call pill, the status-bar indicator, the lock-screen and CarPlay call screens, and a real entry in the system Phone app's Recents (and CarPlay's native call screen) — so a user can redial the agent from the car's built-in phone screen without opening the app. Because of that, the in-app Recents partly duplicates the system's; keep it a convenience, not an over-built second home.

## In-call behavior

**Listening.** Default to always-listening with barge-in: the mic stays open, the agent's own turn detection handles pauses, and mute is the gate. A global push-to-talk option lives in Settings (defaulted off) — not a mere preference but the noise-robustness escape hatch for a loud cabin where always-listening misfires on road and wind noise. Global, not per-agent. One real limitation has to be surfaced to the user, because it cuts against the hands-free premise: push-to-talk only works while the app is in the foreground, since the talk button lives on the in-call foreground screen — when the phone is locked or the screen is off (the usual driving case), the system call UI is showing instead and there is no button to hold. The push-to-talk toggle's footer must warn about this plainly, so the user understands push-to-talk is a quiet-cabin control, not something usable with the screen locked while driving.

**Reconnection.** A dropped connection — tunnels, dead zones — is the defining driving problem: CallKit still thinks the call is up while the WebRTC media is gone. On a drop, attempt to reconnect with exponential backoff while the status line shows the state, and end cleanly only if recovery fails. Because the agent is exactly what's unreachable during a drop, the app speaks the state itself, in a deliberately robotic built-in-synthesis voice (intentionally distinct from the agent's voice, since this is external to the conversation): "Connecting" roughly every seven seconds while connecting, "Connected" once on connect, "Disconnected" on a drop, and "Retrying connection" roughly every seven seconds while retrying. This gives the driver transparency precisely when they can't hear the agent. (If the stock voice grates, swap in custom recordings later.)

**Interruptions.** Duck the call audio under navigation prompts, notifications, and other transient system audio, then recover. The exception is a real incoming phone call: yield entirely — pause or end the agent call — because the human caller takes the audio route and you can't meaningfully talk to both at once.

**Permissions, in context.** Ask for the microphone when the first call starts, Contacts only when the mirror toggle is flipped, and Siri later — never a wall of prompts on launch, because a permission asked with obvious context is the one that gets granted.

## Scope, transports, and platform

**In scope for the build:** multiple agents with the full bring-your-own add/edit configuration; the three-tab Phone-style app; Agent Detail; the in-call foreground screen; the system-contact mirror; reconnection with spoken state; always-listening with a global push-to-talk setting; the test-connection check.

**Transports.** Daily and the transports LiveKit supports — the same Pipecat iOS client with a swapped transport, so the second is cheap. You never integrate model APIs (OpenAI Realtime, Gemini Live, and so on) directly; they ride inside the agent over the same transport, so supporting the orchestration transports transitively covers every model and voice. SmallWebRTC — serverless, the closest match to the ntfy self-host ideal — is a later transport; peer-to-peer over cellular needs NAT-traversal help, so the cloud transports stay the default for "works anywhere."

**Connection.** Pure bring-your-own credentials minted by the user's own Daily/LiveKit — no token service, no backend, zero cost. For now the user enters the connection in the add/edit sheet; a QR flow that encodes a *pairing endpoint* (a URL the app calls for a fresh room and token per call, rather than a token that goes stale) is the later, more ntfy-like shape, supported by a published connection spec and a snippet a coding agent can wire into the user's server.

**Platform.** Target the iPhone 17 on the latest iOS with the active developer account, as a personal/development build that needs no entitlement to run on your own device. Capabilities: the Voice-over-IP background mode and a microphone-usage description. PushKit is skipped — it's only for incoming calls, and every call here is user-initiated.

## Deliberately out of scope / fast-follows

The CarPlay dashboard app and its entitlement and templates; the QR / pairing-endpoint onboarding; SmallWebRTC as a transport; reliable lock-screen "Hey Siri, call my agent" dialing; a Favorites tab; and cross-drive persistent memory (which lives in the agent). Agent design itself is handled separately and is not a concern of this plan. Each is a known next step, not a gap.

## To verify on device (not decide)

Three things are settled in design but need confirming on real hardware: that the mirrored contact's photo actually renders on the CarPlay and lock-screen call UI across iOS versions; the locked-screen Siri dialing path; and the CallKit↔WebRTC audio-session handshake. None changes the design; each is a "see it work" item.

## A realistic target

A working app with the three-tab structure, at least one agent added through the bring-your-own sheet, and a real, car-routed voice call to it — placed from the app, audio through the car over Bluetooth — with mute, native route-switching, reconnection-with-spoken-state, and the system-contact mirror in place.

A useful sequencing tip: point the app at a trivial echo/parrot agent first — one that just repeats or greets — so you're debugging the call-and-audio plumbing in isolation before any real agent logic enters the picture. Once a dumb agent comes through cleanly in the car, swapping in a real Pipecat agent is a configuration change, not a debugging session.

## Testing and the iteration loop

The simulator can't exercise the core of this app: CallKit doesn't run there, and the WebRTC client can't capture the microphone in the simulator, so a real two-way call is device-only. The loop is therefore layered, and only the top layer is manual.

**Layer 1 — logic, in the simulator, fully automated.** With the CallKit and transport boundaries behind protocols, the call state machine, connection/pairing parsing, transport selection, and error handling all unit-test against fakes at simulator speed and run in CI. This is where most bugs live, so it carries most of the load. A CallKit-free debug path that just joins a room and plays inbound audio also runs in the simulator, letting you iterate on signaling and connection independently of CallKit — with the caveat that the simulator can play inbound audio but can't publish the mic, so this validates connect-and-downlink, not a full conversation.

**Layer 2 — integration, on a tethered device, scripted.** `xcodebuild test` against the wired iPhone runs genuine, live calls: the harness taps "call," the app opens a real CallKit + WebRTC session, and you assert on the actual call lifecycle — started, connected, audio session activated, mute, ended. Pre-grant the microphone permission in test setup so the harness doesn't stall on the system prompt. The boundary worth knowing: these tests drive the app's own UI and read the app's call state; they cannot reliably touch the system-rendered CallKit UI (the native route picker or answer screen, which live in a separate process) or verify that audio was actually audible. So Layer 2 proves the call machinery, not the sound.

**Layer 3 — audio and routing, manual, minimized.** AirPods stand in for the car. Place a call and use the route control to switch between AirPods and speaker; because a car connected over plain Bluetooth uses the same hands-free call-audio path as AirPods, this validates the route-switching and two-way audio without a vehicle. The user handles their own car pairing or CarPlay connection, which from the app's side is just another audio route. Two things to keep in mind: AirPods proxy the plain-Bluetooth car case but not CarPlay-specific audio or dashboard behavior (acceptable while CarPlay is deferred; the dashboard version will need a real CarPlay check), and call audio over any Bluetooth device drops to hands-free call quality rather than music quality — a Bluetooth-link limitation, not a flaw in the WebRTC path, and the one spot the wideband advantage is partly eaten (less so on LE Audio–capable hardware). On speaker or wired, the full quality is there.

Layer 2 and Layer 3 are complements: the automated device tests confirm a real call connected and behaved correctly, and the manual AirPods/speaker toggle covers exactly the routing-and-audio piece the automation structurally can't reach. Keep agent iteration decoupled from app iteration: develop and test the Pipecat agent separately in Python so agent changes never trigger an iOS rebuild; only rebuild the app when the client itself changes.

## Risks to watch

- **The CallKit ↔ audio-session timing** is the most likely place to lose hours. Treat the system as the owner of the session and attach media on activation; don't let WebRTC seize the mic independently.
- **The system-contact mirror has lifecycle edges** — the Contacts permission, keeping the mirror in sync on edit and delete, and contacts lingering after the app is removed — so treat it as real work, not a free toggle.
- **SmallWebRTC over cellular** will need TURN; don't assume pure peer-to-peer reaches a home server from the road (relevant when that transport is added).
- **Lock-screen Siri calling** behaves inconsistently without careful intent handling — budget for it as its own task rather than a quick add-on.
