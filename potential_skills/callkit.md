# CallKit ↔ transport timing

Pre-flight checklist for the CallKit/audio/transport seam. CallKit's request→delegate
round-trips and its activation timing are driven by the system, not your call site —
and the in-app fakes don't model that round-trip, so these bugs pass the sim suite and
only appear on device. Read before touching `CallSessionCoordinator`, `SystemCallProvider`,
or a `Transport` adapter's connect/audio path.

### System callbacks fire more than once and out of order vs. your code
First seen: 2026-06-07
Last seen: 2026-06-08
Occurrences: 2

**Pattern:** Logic that assumes a single, ordered sequence breaks when CallKit
re-enters or reorders. (1) Ending a call by requesting the system end AND driving the
terminal transition double-fired, because the real `CXEndCallAction` round-trips back
through `providerPerformEndCall` (two call-log rows). (2) `providerDidActivate` fired
BEFORE the transport finished connecting (a slow pairing fetch), so a one-shot
`setMicEnabled` no-op'd on a not-yet-joined client (dead mic).

**Rule:**
- Make every terminal transition idempotent (`guard !state.isTerminal`) and clear
  `activeCallID` on teardown, so a late/duplicate system callback is inert.
- Treat audio activation and transport-connected as two unordered edges: re-apply
  mic/route state on BOTH (`providerDidActivate` and `.connected`), gated by an
  `isAudioActivated` flag, so whichever lands last leaves the correct state.
- Never assume "I requested X, so X happens once, now." The system decides when and
  how many times.

**Why it's missed:** The fakes (`FakeCallProvider`, `FakeTransport`) don't round-trip
through the delegate and aren't connection-gated, so the unit suite shows one clean
ordered pass. The misbehavior is device-only — verify the call lifecycle on hardware,
and when a device bug appears, add the diagnostic to the debug spike's file log
(os.log isn't capturable with the env-driven launch).
