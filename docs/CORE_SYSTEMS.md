# Core Systems

> Skeleton placeholder. Conduit is a brand-new app with no feature code yet. This
> document will grow to capture the shared, app-agnostic infrastructure as it
> lands. Nothing below is implemented yet — these are the systems the
> architecture (see [ARCHITECTURE](./ARCHITECTURE.md)) anticipates.

## What this will document

As the call/transport layers are built, document each here:

### Call state machine

The lifecycle of a call as a single source of truth — `idle → connecting →
connected → reconnecting → ended` (with failure states surfaced as red "missed"
entries in Recents). This is the most testable surface (voice plan "Layer 1");
it should live behind no UIKit/CallKit dependency so it unit-tests at simulator
speed.

### Transport abstraction

The protocol boundary over the Pipecat iOS client that makes Daily / LiveKit (and
later SmallWebRTC) swappable, and lets the call logic test against fakes. Covers
connection/pairing parsing and transport selection.

### Audio-session / CallKit integration

The key seam: CallKit owns audio-session activation, and the WebRTC media attaches
on activation rather than seizing the mic. Document the provider/call-controller
wiring, the activation handshake, and route defaults (speaker / Bluetooth, never
earpiece — it's a hands-free call).

### Reconnection logic

Exponential-backoff reconnection for dropped WebRTC media (CallKit still believes
the call is up), plus the spoken-state behavior in a built-in synthesis voice
("Connecting" / "Connected" / "Disconnected" / "Retrying connection") and the
interruption/ducking rules.

## Shared utilities (already present)

- **`Log`** (`Core/Utilities/Log.swift`) — categorized os.log logging facade. See
  [CONVENTIONS § Logging](./CONVENTIONS.md#logging).
- **`AccessibilityID`** (`Core/Utilities/AccessibilityID.swift`) — base namespace
  for accessibility identifiers. See
  [CONVENTIONS § Accessibility](./CONVENTIONS.md#accessibility--the-accessibilityid-convention).
