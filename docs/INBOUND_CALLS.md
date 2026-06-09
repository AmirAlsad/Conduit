# Conduit Inbound Calls (agent-initiated)

This document describes how *your* server makes **Conduit ring the user** — an
agent-initiated inbound call, delivered to the lock screen and CarPlay like any
phone call, then connected over the same WebRTC transport as an outgoing call. Hand
it to whoever runs the agent's backend. It is the inbound companion to
[CONNECTION_CONTRACT](./CONNECTION_CONTRACT.md) (outbound); read that first.

**Still no backend of ours.** Inbound needs a VoIP push, and Apple ties VoIP push to
the *app's* APNs key. Because Conduit is **self-built and self-signed** — you build
it under *your own* Apple Developer team — *you* hold the APNs key and *your* server
sends the push directly to Apple. The user's VoIP token only ever travels to your
own server. Anthropic/Conduit operates nothing at runtime.

---

## 0. One-time prerequisites (device)

- Build Conduit under **your own Apple Developer team** with the **Push
  Notifications** capability. The app already declares the `aps-environment`
  entitlement (`Conduit/Conduit.entitlements`) and the `voip` + `audio` background
  modes; you must enable Push Notifications on the App ID (a **paid** Apple Developer
  account).
- Create an **APNs auth key (`.p8`)** in your developer account and put it on your
  server. The VoIP push **topic** is `<your-bundle-id>.voip` (e.g.
  `com.yourname.Conduit.voip`).

Inbound is **opt-in per agent**: in Add Agent, toggle **"Let this agent call me"** and
give a **registration endpoint** (pre-filled from the pairing endpoint, editable).

---

## 1. Token registration

When the user enables inbound for an agent (and whenever iOS refreshes the token),
Conduit POSTs its device VoIP token to that agent's registration endpoint. Store it,
keyed to the user/agent, for use when you want to ring them.

### Request

```
POST <your registration endpoint>
Content-Type: application/json
Authorization: Bearer <API key>      # the agent's key; omitted if blank

{
  "voip_token": "<hex APNs VoIP token>",
  "platform": "ios",
  "bundle_id": "<the app's bundle id>",
  "agent_id": "<the agent's UUID in the app>"
}
```

- The **VoIP token is per-install, app-wide** (not per-agent, not per-transport). The
  same token is registered with every agent the user opted in — each of your servers
  sees its own copy.
- Authenticate with the bearer key however you like (same key as the pairing
  endpoint). Return any 2xx.

---

## 2. Ringing the user

Send a **VoIP push** to APNs for the stored token.

```
POST https://api.push.apple.com/3/device/<voip_token>
apns-topic: <your-bundle-id>.voip
apns-push-type: voip
authorization: bearer <APNs JWT signed with your .p8>

{
  "agent_id": "<the agent's UUID>",   // required — which agent is calling
  "call_id":  "<a UUID you mint>",     // used as the CallKit call id
  "room_url": "<optional>",            // inline credentials (see hybrid below)
  "token":    "<optional>"
}
```

### Credentials: hybrid (inline **or** pairing)

On answer, Conduit needs a room + token to join. You choose how it gets them:

- **Inline** — include `room_url` + `token` in the push. Conduit joins directly. Works
  for any agent (including direct-room agents). Use short-lived join tokens.
- **Via pairing** — omit `room_url`/`token`. After the user answers, Conduit resolves
  the agent's **pairing endpoint** exactly as for an outgoing call (see
  CONNECTION_CONTRACT). Nothing sensitive rides the push. Requires a pairing endpoint.

`room_url` is Daily's `https://…` room or LiveKit's `wss://…` URL, matching the
agent's transport — same shapes as the pairing response.

---

## 3. What the app does

1. **Push received** → Conduit reports an incoming call to CallKit and rings
   (`incomingRinging`). It must report synchronously, so the push need only carry
   `agent_id` + `call_id`; credentials are used later.
2. **User answers** → Conduit connects the transport (inline creds, else pairing
   resolve), transitions to `connecting` → `connected`, and the call behaves exactly
   like an outgoing one (mute, routing, reconnection, interruptions).
3. **User declines** (or the call is never answered) → logged in Recents as a declined
   **incoming** call.
4. **Unknown `agent_id`** (not configured in the app) → Conduit still reports the call
   to satisfy PushKit, then ends it gracefully.

---

## Notes & caveats

- **Device + paid account only.** None of this runs in the iOS Simulator (no CallKit,
  no PushKit). Verify on hardware.
- **Privacy.** The VoIP token is not a secret credential, but treat it with care: a
  party holding both your APNs key and a device token can ring that device. Keys live
  on your server; tokens are sent only to servers the user opted into.
- **One call at a time.** Conduit handles a single call; a push that arrives mid-call
  is ignored.
