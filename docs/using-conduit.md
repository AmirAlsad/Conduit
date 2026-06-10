# Using Conduit

The longer explanations behind the app's settings and behaviors. Each section
here is linked from the matching "Learn more" in the app.

## Push to talk

By default the agent is **always listening** during a call — talk naturally, as
on a phone call. Turning on **Push to talk** (Settings → Audio) inverts that: the
microphone opens only while you hold the talk button on the in-call screen, and
stays closed the rest of the time. Use it in noisy places, or when you want
positive control over exactly what the agent hears. The mute button still works
in both modes; push-to-talk simply adds a second gate.

## Daily audio routing

On **Daily** calls, switch the speaker / Bluetooth / earpiece output from
**Conduit's in-call controls**, not the system call screen. Daily's SDK manages
the audio session itself and doesn't follow the native call screen's audio
button — taps there appear to do nothing. Conduit's own route picker drives the
SDK directly, so it always works.

**LiveKit** calls don't have this limitation: Conduit runs LiveKit in manual
audio mode, the system owns the audio session, and the native call screen's
audio button moves the sound like any phone call.

## Call with Siri

Two ways to dial hands-free:

- **"Hey Siri, call \<agent\> on Conduit"** — the app's own Siri phrase. Variants
  like "dial … on Conduit" and "make a Conduit call" (which asks which agent)
  work too. This path opens the app to place the call, so on a locked phone Siri
  asks you to unlock first.
- **"Hey Siri, call \<agent\>"** — without the app name. Siri may ask whether to
  use Conduit or Phone the first time; this route works from the lock screen.

Setup notes:

- The first launch asks for **Siri permission** — if you declined it, flip
  **Settings → Apps → Conduit → Siri & Search → Use with Siri Requests**.
- Siri learns your agents' names from the app; after **adding or renaming an
  agent**, give it a minute (vocabulary refresh isn't instant).
- Agent names that are real words or common names recognize best.

Because the call action is a system **App Intent**, it also appears in the
**Shortcuts app** — you can embed "Call Agent" in your own shortcuts and
automations (for example: when my phone connects to the car's Bluetooth, call
my agent).

## Add to Contacts

**Add to Contacts** (Agent Detail) saves the agent as a regular iOS contact —
through the system's own Add Contact sheet, so Conduit never requests Contacts
permission and never reads your address book. With the contact saved, the
agent's name and photo appear everywhere the system shows a caller: the lock
screen, the full-screen call UI, Bluetooth devices, and your car's display.
Editing the agent later keeps a linked contact's name and photo in step.

## Privacy

Conduit is a thin, private pipe to your own voice agent:

- **No Conduit server.** The app talks only to endpoints you configure — your
  pairing endpoint, your room provider (Daily/LiveKit), your inbound
  registration endpoint. There are no accounts and no analytics.
- **Credentials stay on the device.** API keys and room tokens live in the iOS
  Keychain. They are never uploaded anywhere except as the bearer token to
  *your own* endpoints, never logged, and never written into a contact.
- **The audio goes agent-to-app.** Calls are WebRTC sessions between your phone
  and the room your server provisioned. Conduit adds no middle hop.
