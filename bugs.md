# Bug Log

Auto-memory: bugs hit while working, newest first. Check here (and
`potential_skills/`) before debugging. On the 2nd occurrence of a class of bug,
promote it to `potential_skills/<domain>.md`. Format/lifecycle:
`potential_skills/README.md`.

---

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
