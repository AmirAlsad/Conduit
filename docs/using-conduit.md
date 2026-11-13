# Using Conduit

The longer explanations behind the app's settings and behaviors. Several
sections here are linked from a "Learn more" in the app.

## Push to talk

By default the agent is **always listening** during a call — talk naturally, as
on a phone call. Turning on **Push to talk** (Settings → Audio) inverts that: the
microphone opens only while you hold the talk button on the in-call screen, and
stays closed the rest of the time. Use it in noisy places, or when you want
positive control over exactly what the agent hears. The mute button still works
in both modes; push-to-talk simply adds a second gate.

## Where the sound comes from

A call starts like a phone call: on the earpiece, unless AirPods, headphones or
your car are connected, in which case it plays there. Conduit never switches to
the loudspeaker by itself. Hold the phone to your ear, or switch to the speaker
from Conduit's in-call controls (or, on LiveKit calls, the system call screen's
audio button). Your choice stays for the rest of the call, through a reconnect.

## What you hear

Conduit marks the moments of a call with a ring and a few short words, in a plain
system voice that is not your agent's:

- **A call you place:** after about half a second, a ringing tone; then
  "Connected". Your microphone stays closed while these play, so your agent does
  not hear them; once "Connected" has finished, the call is yours.
- **A call from your agent that you answer:** if your agent is already on the
  line, nothing at all: you are straight into the conversation. If it is still
  connecting a second after you answer, you hear "Connecting" once, then
  "Connected" when it arrives. There is no ringing tone after you answer.
- **When the connection drops:** "Disconnected", then "Retrying connection" every
  few seconds while Conduit reconnects, then "Connected" when the call is back.
  You can talk again as soon as it is back. If the connection stays down for more
  than about a minute, the call ends and Recents shows **Failed — connection lost**.

At your ear the ringing tone is quiet, like a phone's; in AirPods or headphones it
plays at the call volume, and the volume buttons change it.

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
  work too. This path opens the app to place the call, so it needs the phone
  unlocked (on a locked phone Siri should ask you to unlock; it may just decline).
- **"Hey Siri, call \<agent\>"** — without the app name. This rides Siri's
  calling domain, which anchors the spoken name against your **Contacts** —
  so it only works for agents you've added with **Add to Contacts** (Agent
  Detail). With the contact saved, Siri may ask whether to use Conduit or
  Phone the first time; for an agent with no contact, Siri silently gives up
  or snaps to the nearest real contact.

Reliability honesty: Siri's recognition of app phrases can lag installs,
renames, and reboots (launch the app once and give it a minute), and
lock-screen / app-not-running dialing is inconsistent on current iOS —
treat those as best-effort until the iOS 27 App Intents calling schema lands.

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

## Calls from your agent

If your agent's backend supports it, your agent can **call you** — the app rings as
a normal incoming call, even from the lock screen, showing the agent's name and
photo (once you've added it to Contacts). Turn it on per agent with **"Let this
agent call me"** in the agent's settings, which registers your device with your
backend. Conduit asks for the microphone then, so that a call you answer from the
lock screen can carry your voice. A call that rings out, or that your agent
withdraws, shows in **Recents** as missed, with a quiet notification.

!!! warning "Not ringing? Check Focus / Do Not Disturb"
    Depending on your iOS version and Focus settings, iOS may silence incoming calls
    while a **Focus** or **Do Not Disturb** is on. The call still arrives — it just
    won't ring or light up the lock screen, and even the quiet missed-call
    notification may be filtered. You'll still find it in the **Recents** tab, marked
    as missed. To let your agent ring through, turn off Focus/DND, or
    allow calls from the agent's contact in your Focus settings. (If it's missing from
    Recents entirely, inbound isn't registered — re-toggle "Let this agent call me",
    and make sure you're testing on a real device, not the simulator.)

## Missed calls

A ring you never answered or declined shows in **Recents** as **Missed**, in red,
like a missed call in the Phone app, and Conduit posts a quiet notification. That
covers a call that rang out, one your agent withdrew before you picked up, one that
arrived while you were already on a Conduit call (**Missed — on another call**; its
notification says it came "during another call") and one that iOS silenced for a
Focus (**Missed — Focus**). The last two never rang, so the row says why. A call you
declined shows as **Declined**.

## Phone calls during a call

Conduit calls can't be put on hold yet. If you accept or place a phone call
during a Conduit call, iOS ends the Conduit call, and it shows in Recents as a
completed call; call the agent again once you're done. Declining the phone call
leaves the Conduit call as it is.

## Microphone access

Conduit asks for the microphone the first time you place a call, and when you turn
on **Let this agent call me** (so a call you answer from the lock screen can carry
your voice). If you said no, Conduit does not place a call the agent could not
hear: it tells you so, with a shortcut to Settings. Under the inbound toggle you
will see a note while access is off. Allow it in **Settings → Apps → Conduit →
Microphone**.

## When your agent doesn't join

If Conduit reaches the call but your agent is not ready within 30 seconds, the
call fails with **Agent didn't join**, and Recents reads **Failed — agent didn't
join**. The connection to the room worked; the problem is on your server's side.
Check that your server starts the agent for each call (for pairing, when it returns
credentials; for direct mode, from the room webhook), and that the agent can
actually start (its model keys, for instance). If your agent legitimately needs
longer than 30 seconds to start, have the server start it earlier or warm it up.
Other failures read **Authentication failed** (check the API key),
**Connection lost** (the network dropped) and **Couldn't connect** (check the
transport setting and your server's credentials).

## Add to Contacts

**Add to Contacts** (Agent Detail) saves the agent as a regular iOS contact —
through the system's own Add Contact sheet, so adding it needs no Contacts
permission. With the contact saved, the agent's name and photo appear everywhere
the system shows a caller: the lock screen, the full-screen call UI, Bluetooth
devices, and your car's display.

When you later edit an agent you've added, Conduit keeps that one contact's name
and photo in step. To do that it asks for Contacts access the first time; if you
say no, the contact simply keeps its old name and photo. Conduit only ever opens
the agent's own contact: it does not read, upload or change your other contacts.

## Privacy

Conduit is a thin, private pipe to your own voice agent:

- **No Conduit server.** The app talks only to endpoints you configure — your
  pairing endpoint, your room provider (Daily/LiveKit) or your own machine
  (SmallWebRTC), your inbound registration endpoint — and, when your server asks
  for it, reports how each ring from your agent ended to the address your server
  names. Rings reach you through Apple's push service. There are no accounts and
  no analytics.
- **Credentials stay in your Keychain.** API keys and room tokens live in the iOS
  Keychain. They are sent only as the key to *your own* endpoints (including that
  ring-status address), never logged, and never written into a contact.
- **The audio goes agent-to-app.** Calls are WebRTC sessions between your phone
  and the room your server provisioned. Conduit adds no middle hop.

The full details are in the [Privacy Policy](privacy.md).
