# Device Verification Run Sheet

The reusable by-hand checklist for everything the simulator cannot run: real
CallKit calls, two-way WebRTC audio, routing, VoIP-push rings, Siri dialing. It is
used for a before/after comparison around any change that touches the call stack
(first use: the call-engine extraction into a Swift package) and again after every
transport-SDK bump. Internal; not published on the docs site.

Transports are written out in full (Daily, LiveKit, SmallWebRTC) so they don't
collide with the row ids (`S1` is Siri, `L1` is links).

## How to use this

- **Hold the environment constant across the two runs.** Same phone, same iOS
  version, same backend deployment (same commit, same env vars, same volume), same
  three agents in the app, same network. Debug builds both times (the call trace in
  this doc only exists in Debug).
- **Run 1 on the old build, run 2 on the new build installed over it.** Fill the
  **Before** column on run 1. For run 2, install the new build over the old one
  *without deleting the app* (that is row M1), then fill the **After** column.
- Mark each cell `P` (pass), `F` (fail, with a one-line note), or `-` (not run).
  Rows that are known limitations or never verified (O4 on Daily, O10) record what
  happened rather than pass/fail.
- **A failure in After is a regression only if that row passed Before.** A row that
  failed or was `-` in Before is a pre-existing gap, not caused by the change.
- N-rows are After-only; leave Before as `n/a`.
- **Suggested order.** After run only: M1 first, before anything touches the data.
  Then I1 (registers the token), the O rows, the other I rows, S, L, B2. Do the
  destructive rows last: I7 (deletes a throwaway agent) and I9 (deletes an agent
  and its Recents history), then re-add the agent with the L1 QR.
- Log lines quoted below (`teardown.end_now`, `inbound.ring_status`, ...) are
  emitted by the reference engine in `example-backend/`; pass conditions that cite
  them assume that engine.

## Setup

### What must be running

| Piece | Notes |
|---|---|
| Deployed engine (HTTPS) | The reference engine, with `ENGINE_API_KEY`, Daily and LiveKit keys, the `APNS_*` vars, and the registry on a volume (`REGISTRY_DB_PATH=/data/registry.db`, needed for I8). Same deployment both runs. |
| Daily agent | An app agent on transport Daily, pointing at `https://<host>/connect/loopback` (the echo agent: when you mute, the echo stops, which makes O3 audible). |
| LiveKit agent | An app agent on transport LiveKit, pointing at `https://<host>/connect/live` (needs the model keys) or another engine agent id. |
| SmallWebRTC agent | An app agent on transport SmallWebRTC, pointing at a **local** engine on the Mac, with the Mac joined to the phone's hotspot (media is UDP; it will not work through Railway). |
| Inbound toggle | "Let this agent call me" on for the Daily and LiveKit agents only. The registry is keyed by *engine* agent id and the latest registration wins, so the two inbound agents must point at different engine agent ids (loopback and live above). |
| Siri contact | "Add to Contacts" done for the agent you use in S2. |

Pairing links with the key embedded are secrets: do not screenshot them or paste
the QR anywhere.

### Local engine for SmallWebRTC

```bash
cd example-backend
uv run uvicorn app.main:app --host 0.0.0.0 2>&1 | tee /tmp/conduit-verify/engine-local.log
uv run python scripts/pair.py --agent loopback --transport smallwebrtc \
    --base-url http://$(ipconfig getifaddr en0):8000
```

Allow the iOS local-network prompt on first connect (and macOS firewall prompts).

### Tail the deployed engine log

Dashboard: service, Logs. Or from a terminal linked to the Railway service:

```bash
mkdir -p /tmp/conduit-verify/before /tmp/conduit-verify/after   # one dir per run
railway logs 2>&1 | tee /tmp/conduit-verify/before/engine.log \
  | grep --line-buffered -E 'teardown\.|bot\.|dispatch\.|inbound\.|apns\.|engine\.'
```

TODO(verify): `railway logs` is not documented anywhere in this repo; confirm the
subcommand and flags for your CLI version, or just copy from the dashboard.

Useful lines (all emitted by `app/obs.py`'s `event()`; the bot subprocess inherits
the dispatcher's stdout, so they interleave in one stream):

| Line | Meaning |
|---|---|
| `dispatch.accepted room=<key> agent=<id> pid=<n>` | Pairing call: bot spawned. `<key>` is what `/admin/disconnect` needs. |
| `teardown.first_human` / `teardown.human_joined` | The app joined the room (Daily, LiveKit). |
| `bot.end_call_signal` then `teardown.end_now reason=client-end-call` | Deliberate hang-up, ended at once. |
| `teardown.end_now reason=client-left` | SmallWebRTC peer dropped (also immediate). |
| `teardown.human_left`, `teardown.grace_started`, `teardown.grace_cancelled` | A drop; a rejoin inside the window cancels teardown. |
| `teardown.grace_expired` | **Bad on a deliberate hang-up.** Normal only after a real outage (O7). |
| `dispatch.bot_exited room=<key> pid=<n> code=<n>` | Bot process gone. |
| `inbound.registered agent=<id> platform=ios bundle=<id>` | Token registration. |
| `inbound.unregistered agent=<id>` (preceded by `inbound.token_evicted`) | The app's DELETE was honored. |
| `apns.push_sent status=200 ...` | APNs accepted a ring. |
| `inbound.ring_status agent=<id> call_id=<id> status=<s>` | Receipt: `answered`, `declined`, `busy`, `suppressed_by_focus`. |

### Send a ring

```bash
cd example-backend      # ENGINE_API_KEY comes from .env
uv run python scripts/ring.py --agent loopback --base-url https://<host>
uv run python scripts/ring.py --agent live --base-url https://<host>
# credentials in the push (provisions a room, dispatches the bot before answer):
uv run python scripts/ring.py --agent live --inline --transport livekit --base-url https://<host>
```

`ring.py` prints the call id and either `Rang as: <name>` or `No caller name: this
registration predates names...`. On failure it prints the HTTP status and a hint
(404: no registration for that agent; 502: APNs rejected; 503: APNs not configured).

### Force a server-side drop

```bash
curl -s -X POST https://<host>/admin/disconnect \
  -H "Authorization: Bearer $ENGINE_API_KEY" -H "Content-Type: application/json" \
  -d '{"room_key":"<room from dispatch.accepted>"}'
```

Logs `dispatch.admin_disconnect`. Daily and LiveKit only; SmallWebRTC bots run
in-process and have no room key.

### Pulling the call trace (Debug builds)

While the in-call screen is presented, the Debug build appends one line per change
(`state=... muted=... audioActivated=... selected=... activeRoute=[...] devices=[...]`,
polled every 250 ms) to `Documents/conduit-call-trace.log` in the app container
(`Conduit/Debug/CallTrace.swift`, written from `InCallView`). Constraints:

- **The file is truncated at the start of every call** (and again each time the
  in-call screen is re-presented after being minimized). Pull it right after each
  key call, before the next one.
- A call answered from the lock screen only starts tracing once the in-call screen
  is presented.

```bash
BUNDLE_ID=$(awk -F'= *' '/^APP_BUNDLE_IDENTIFIER/{print $2}' Config/local.xcconfig)
RUN=/tmp/conduit-verify/before        # or /after
xcrun devicectl device copy from --device "<device name or UDID>" \
  --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
  --source Documents/conduit-call-trace.log \
  --destination "$RUN/trace-<row>-<transport>.log"
```

`xcrun devicectl list devices` shows the device name and UDID. The same `TRACE`
lines also go to os.log (category `call`) if you have Console.app attached.

## Run sheet

`Before` / `After`: `P`, `F` + note, `-`, or `n/a`.

### Outgoing calls

| # | Check | Steps | Pass when | Before | After |
|---|---|---|---|---|---|
| O1 | Cold launch, immediate call (Daily, LiveKit) | Force-quit the app. Launch from Home and tap Call on the agent within a few seconds. Repeat per transport, force-quitting between. Pull the trace. | You hear "Connecting" then "Connected"; you hear the agent and it hears you; orange mic indicator is on; trace shows `audioActivated=true` and a `connected` state. | | |
| O2 | Warm call (Daily, LiveKit, SmallWebRTC) | Without force-quitting, call each agent in turn (SmallWebRTC over the hotspot LAN, local engine running). Talk about 30 s each, then hang up. | Two-way audio and mic indicator on every transport; each call ends cleanly. | | |
| O3 | Mute sync | On a connected call, mute in-app. Lock the phone (or use the call pill / lock-screen call UI) and check the native Mute. Toggle from the native side, then back in-app. | In-app and native mute always agree; while muted the agent does not hear you (echo stops on loopback); unmute restores it. Trace `muted=` follows. | | |
| O4 | Route picker and native route button (Daily, LiveKit) | With AirPods or other Bluetooth connected: use the in-app route picker to move Speaker / Receiver / Bluetooth on each transport. Then use the native call screen's audio button. | In-app picker audibly moves the sound on both transports. Native button audibly moves it on LiveKit. **Daily native button: known limitation, record what happens** (expected: route metadata changes, audio does not move). Trace `activeRoute=` matches. | | |
| O5 | Lock mid-call | Start a call, lock the phone, wait 30 s, look at the lock screen. | Audio continues both ways; lock screen shows the agent's name (and photo if linked to a contact) and a timer that matches the in-app one. | | |
| O6 | Reconnection (Daily, LiveKit) | (a) Find `room` in `dispatch.accepted`, send `/admin/disconnect` for it. (b) Separately, with a new call: airplane mode on for 5 s, then off. Pull the trace after each. | You hear "Retrying connection" (repeats about every 7 s while down), then "Connected", and audio resumes with no input from you; the call is still one call. Engine shows `teardown.human_left` then `grace_started` then `grace_cancelled` or `human_joined`, never `grace_expired`. For (b) on both Daily and LiveKit, expect "Disconnected" within a second or two of airplane mode on (Daily infers it from the network path, LiveKit from its SDK), then "Retrying connection", then "Connected" soon after airplane mode off; if "Connected" is heard but audio stays silent for more than a few seconds, record it (Daily announces recovery when the path returns, before its media resumes). TODO(verify): what the app does after the bot is killed by `/admin/disconnect` (re-pair vs. end); record the observed behavior. | | |
| O7 | Outage past the retry budget | Mid-call, airplane mode on and leave it for 3 minutes (budget is 6 attempts, 1 s base, 30 s cap, roughly a minute of backoff). Then turn it off. | You hear "Disconnected"; the call ends by itself; no CallKit call or pill lingers; Recents shows one row reading "Failed — connection lost". Engine shows `grace_expired` for that room. "Connected" is never heard while airplane mode is on; on LiveKit, a "Connected" about a minute in followed by a silent running call is the abandoned-reconnect bug. | | |
| O8 | Hang-up is immediate (Daily, LiveKit, SmallWebRTC) | On each transport, end a call in-app. Repeat, ending from the lock-screen call UI. | Engine log within about a second: `bot.end_call_signal` and `teardown.end_now reason=client-end-call` (SmallWebRTC may show `reason=client-left` instead); no `grace_started` or `grace_expired` for that room; `dispatch.bot_exited` follows (Daily, LiveKit). One Recents row per call, no duplicates. | | |
| O9 | Wrong API key | Edit the Daily agent, change the API key to a wrong value, Save, call. Restore the key afterwards. | Call fails fast; in-call status reads "Authentication failed" with the hint "Check the API key in this agent's settings."; Recents row reads "Failed — authentication". | | |
| O10 | Interruption: Siri or a real phone call (never device-verified before; record on both runs) | On a connected call (a) say "Hey Siri" and ask something; (b) separately, have another phone call yours. Pull the trace. | While the takeover lasts the in-call status reads "Paused" and the agent does not hear you; afterwards the mic resumes by itself and the agent hears you again, call still connected. For (b) also record what iOS offers (hold and accept, decline) and what Conduit does. A failure here is not a regression. | | |

### Inbound calls

Rings use pairing mode unless stated. Kill the app and lock the phone before
sending unless the row says otherwise.

| # | Check | Steps | Pass when | Before | After |
|---|---|---|---|---|---|
| I1 | Registration on save | Edit an agent, toggle "Let this agent call me" off then on (registration endpoint `https://<host>/inbound/register/<engine agent id>`), Save. Do both inbound agents. | `inbound.registered agent=<id> platform=ios bundle=...` appears in the engine log right after Save, without relaunching the app. | | |
| I2 | Cold ring, answer (LiveKit, Daily) | App killed, phone locked. `ring.py --agent <id>`. Answer. Talk. Hang up. | `apns.push_sent status=200`; phone rings on the lock screen showing the agent's name; answering connects with two-way audio; `inbound.ring_status ... status=answered`. Record whether the name was right at ring time. | | |
| I3 | Decline | Ring, decline. Open the app. | Ring dismisses; Recents has a declined incoming row for the agent; `inbound.ring_status ... status=declined`; no `dispatch.accepted` follows (pairing mode starts no bot). | | |
| I4 | Inline credentials | `ring.py --agent <id> --inline --transport <the agent's transport>`. Answer. Do not decline this one (a declined inline bot idles until the pipeline timeout). | `dispatch.accepted` is logged at ring time, before you answer; answering connects directly; two-way audio; `status=answered`. | | |
| I5 | Ring during a call | Start a call with one agent. Ring the other inbound agent. | Active call is unaffected (audio continues, mic indicator stays, app not killed); no incoming-call UI takes over; after hang-up Recents has a missed incoming row; a quiet notification arrives in Notification Center; `status=busy`. | | |
| I6 | Focus filtering | Turn on a Focus that allows no calls (and does not allow Conduit or the agent's contact). Ring with the app killed. | Phone does not ring or light up; APNs still returned 200; Recents has a missed incoming row; a quiet notification arrives; `status=suppressed_by_focus`. Turn Focus off. | | |
| I7 | Unknown agent | Add a throwaway agent "Temp" pointing at `/connect/loopback` with inbound on, Save. Airplane mode on, delete Temp, airplane mode off. `ring.py --agent loopback`. TODO(verify): this relies on the delete's best-effort DELETE failing offline so the registration survives; confirm no `inbound.unregistered` line appeared before you ring. | Phone rings, then ends by itself shortly after answer (or immediately); app is not killed. Then relaunch the app (re-registers the real loopback agent), ring again: it rings normally. | | |
| I8 | Ring after backend redeploy | Redeploy the engine and wait for `engine.started`. Do not open the app. Kill the app, lock the phone, ring. Requires the registry volume. | `ring.py` succeeds (not HTTP 404); phone rings; answering connects. Without the volume this row cannot pass; record "no volume". | | |
| I9 | Delete the agent | Delete an inbound-enabled agent in the app (this wipes its Recents; do it late). Then `ring.py --agent <id>`. | Engine logs `inbound.token_evicted` and `inbound.unregistered agent=<id>`; `ring.py` prints `HTTP 404` (no VoIP registration); phone does not ring. Re-add the agent with the L1 QR afterwards. | | |

### Siri

Needs Siri permission granted and, for S2, the agent saved to Contacts. Siri
recognition can lag after installs; launch the app once and wait a minute.

| # | Check | Steps | Pass when | Before | After |
|---|---|---|---|---|---|
| S1 | App Shortcut phrase, unlocked | Unlocked, say "Hey Siri, call <agent> on Conduit". | Conduit opens and the call dials and connects. | | |
| S2 | "Call <agent>" (SiriKit) | (a) Unlocked: "Hey Siri, call <agent>". (b) Lock the phone and say it again. Choose Conduit if Siri asks Conduit or Phone. | Call dials and connects in both (a) and (b). | | |
| S3 | Siri dial with the app killed | Force-quit the app. Unlocked, say the S1 phrase, then force-quit and say the S2 phrase. | The app launches and the call is placed once the app is active, and connects; no failed or dropped dial. Record the outcome per phrase. | | |

### Links and diagnostics

| # | Check | Steps | Pass when | Before | After |
|---|---|---|---|---|---|
| L1 | Pairing QR | `uv run python scripts/pair.py --agent live --transport livekit --inbound --base-url https://<host>` (add `--no-key` to type the key instead). Scan the terminal QR with the Camera app and open the link. Save. Scan the same QR again. | First scan opens a prefilled Add Agent sheet (name, transport, pairing endpoint, key, inbound endpoint). Second scan of the known endpoint opens Edit on the existing agent, not a duplicate. | | |
| L2 | Test Connection | Open Edit on the Daily and LiveKit agents, tap Test Connection. Then change the key to a wrong value and tap it again; restore the key. | Four stages turn green in order: Pairing endpoint reached, Credentials minted, Transport connected, Agent ready. With the wrong key it fails at **Pairing endpoint reached** with "API key rejected (401)..." and the later stages never run. (The code reports a 401 on the pairing stage, not the credentials stage.) | | |

### Migration and bundle

| # | Check | Steps | Pass when | Before | After |
|---|---|---|---|---|---|
| M1 | Install over the old build | Build the new Debug build and install it with `xcrun devicectl device install app --device "<device>" "$APP"` (no uninstall). Launch. | All agents present; Edit shows the key still stored and Test Connection passes without retyping it; Recents history intact; linked contacts still show "Added to Contacts" and the photo on a call; inbound toggles still on. Before: `n/a` (this row only exists for run 2). | n/a | |
| B1 | No stasel WebRTC | `ls "$APP/Frameworks"` on the built device product (see artifacts). Diff against the Before listing. | No `WebRTC.framework` in `Frameworks/` (the SmallWebRTC fork is built against LiveKitWebRTC); listing matches Before apart from intended changes. | | |
| B2 | Three transports, one launch | Fresh launch. SmallWebRTC call, hang up, LiveKit call, hang up, Daily call; stay on the Daily call at least 60 s talking. Check for new Conduit crash logs (Settings, Privacy and Security, Analytics and Improvements, Analytics Data). | No crash anywhere; two-way audio on each; Daily survives past 60 s (the old collision crashed Daily within seconds of the first participant update). | | |

### After-only

Leave Before as `n/a`. These cover behavior fixed or added by the change.

| # | Check | Steps | Pass when | Before | After |
|---|---|---|---|---|---|
| N1 | Ring from a registration that predates names | Registration made by the Before build (it sent no `display_name`). Install the After build with `devicectl` and **do not launch it** (a launch re-registers with a name). Kill app, lock, `ring.py`. | `ring.py` prints `No caller name`; the phone rings under the agent's local name, with the contact photo if linked. | n/a | |
| N2 | Rename then ring | Rename an agent and Save (re-registers with the new name). Force-quit, lock, ring. | The ring shows the new name; `ring.py` prints `Rang as: <new name>`. | n/a | |
| N3 | Unknown agent shows the pushed name | Repeat the I7 setup (Temp agent registered, deleted offline) and ring. | The ring shows "Temp" (the name carried in the push), not a generic caller name; then ends gracefully. | n/a | |
| N4 | Second ring after an unopened hang-up | Ring, answer from the lock screen, let the agent hang up (`/admin/disconnect` for the room from `dispatch.accepted`). Do **not** open the app. Ring again. TODO(verify): the reference engine has no agent-initiated hang-up besides `/admin/disconnect`, which kills the bot and may look like a drop to the app; if the app reconnects instead of ending, use whatever ends your agent's call from its side. | The second ring rings and can be answered; it is not logged as missed and the receipt is not `busy`. | n/a | |
| N5 | Hang up while "Retrying connection" | Start a call, airplane mode on, wait until you hear "Retrying connection", end the call (in-app, then repeat from the lock screen). Turn airplane mode off, wait 30 s. Pull the trace. | Call stays ended: no further spoken cues, no mic indicator, no call comes back; one Recents row; no new `dispatch.accepted` or `teardown.first_human` for it after you turn the network back on. | n/a | |
| N6 | Hang up in the first second | Call a pairing agent (Daily, then LiveKit) and tap End within a second of tapping Call. Repeat 3 times. | Engine log shows no `teardown.first_human` or `teardown.human_joined` for that room after the hang-up (no zombie join); no mic indicator at any point. TODO(verify): `dispatch.accepted` may still appear because pairing dispatches the bot before the app joins; the proof is the absence of a join line, and the bot lingers until the pipeline idle timeout. | n/a | |

## Objective artifacts to save per run

Everything under `/tmp/conduit-verify/<before|after>/` (outside the repo).

```bash
RUN=/tmp/conduit-verify/before; mkdir -p "$RUN"
git rev-parse HEAD > "$RUN/build-sha.txt"

# Locate and keep the exact device product that was installed (build, then copy at once)
APP=$(xcodebuild -project Conduit.xcodeproj -scheme Conduit -configuration Debug \
  -destination 'generic/platform=iOS' -showBuildSettings 2>/dev/null \
  | awk '/ TARGET_BUILD_DIR =/{d=$3} / FULL_PRODUCT_NAME =/{n=$3} END{print d "/" n}')
cp -R "$APP" "$RUN/Conduit.app"; APP="$RUN/Conduit.app"

ls -la "$APP/Frameworks"                              > "$RUN/frameworks.txt"
codesign -d --entitlements :- "$APP" 2>/dev/null | plutil -p - > "$RUN/entitlements.txt"
plutil -p "$APP/Info.plist"                           > "$RUN/info-plist.txt"
cp Conduit.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved "$RUN/Package.resolved"
```

TODO(verify): the `Package.resolved` path is the usual location for an
XcodeGen-generated project; the project is not generated in every checkout, so
confirm after `xcodegen generate` and a package resolve.

| Artifact | File | Compare |
|---|---|---|
| Engine log | `engine.log` (and `engine-local.log` for SmallWebRTC) | The `teardown.*`, `inbound.*`, `apns.*` lines cited per row; same sequence both runs |
| Call trace, per key call | `trace-<row>-<transport>.log` (at least O1 both transports, O3, O4, O6, O10, N5) | State sequence and `audioActivated` / `muted` / `activeRoute` transitions |
| Frameworks listing | `frameworks.txt` | Identical, no `WebRTC.framework` (B1) |
| Entitlements | `entitlements.txt` | Identical (`aps-environment`, Siri, etc.) |
| Info.plist | `info-plist.txt` | Identical except version/build; background modes and usage strings unchanged |
| Package pins | `Package.resolved` | Only intended pin changes (the SmallWebRTC fork revision, LiveKit and Pipecat versions) |
| Build SHA | `build-sha.txt` | Recorded in the results block |

## Results

Copy one block per run.

### Recorded runs

```text
Run:                 After (call-engine extraction); the Before column was run only for the rows noted below
Date:                2026-11-11
Build SHA:           f790fd3 (smoke test); the full sheet ran on 2bb344b, same engine source
Engine package:      ConduitCallEngine 0.1.1 (5d5cb3b); the full sheet ran on 1758453, same sources
Build config:        Debug, Xcode 27.2
iOS version:         27.0 (24A437)
Phone model:         iPhone 17
Backend deployment:  example-backend run locally on the Mac (LAN), SQLite registry file
Agents used:         Daily=loopback echo   LiveKit=loopback echo   SmallWebRTC=loopback echo
Network:             Wi-Fi (LAN)
Notes / surprises:
  Passed: O1-O9 (O6/O7 on Daily and LiveKit), I1-I5, I7-I9, S1, L1, L2, M1, B1, B2, N1-N6.
  O10 (interruption): Siri cannot be invoked during a call. Placing a cellular call ENDED the
      Conduit call (cleanly, end-call signal sent); it was not paused or held. The engine has no
      hold support. Same on the pre-extraction build by code; not compared on device.
  I6 (Focus): Do Not Disturb did not filter rings on this iOS version, on the pre-extraction
      build or the new one, so the suppressed_by_focus path was not exercised.
  S2/S3 (SiriKit "Call <agent>"): not run; the test agent was not in Contacts. Code unchanged.
  Compared against the pre-extraction build on device: audio route switching, rings under
      Do Not Disturb. Both behaved the same on the two builds.
  Found and fixed during the run: SmallWebRTC pinning the audio route after a LAN call;
      LiveKit reporting connected after an abandoned reconnect; the missed-call notice dropped
      while the app was in front; Daily not reporting short network drops.
  Open: spoken cues are inaudible during Daily calls and during the last retry phase of a
      LiveKit outage. Ringback is silent when the phone is in silent mode (system sound).
```

```text
Run:                 Before / After
Date:
Build SHA:
Engine package:      (ConduitCallEngine commit or version; n/a before the extraction)
Build config:        Debug
iOS version:
Phone model:
Backend deployment:  (host, engine commit, registry volume yes/no)
Agents used:         Daily=      LiveKit=      SmallWebRTC=
Network:             (Wi-Fi / hotspot / cellular)
Artifacts dir:       /tmp/conduit-verify/
Notes / surprises:
```

```text
Run:                 Before / After
Date:
Build SHA:
Engine package:      (ConduitCallEngine commit or version; n/a before the extraction)
Build config:        Debug
iOS version:
Phone model:
Backend deployment:  (host, engine commit, registry volume yes/no)
Agents used:         Daily=      LiveKit=      SmallWebRTC=
Network:             (Wi-Fi / hotspot / cellular)
Artifacts dir:       /tmp/conduit-verify/
Notes / surprises:
```
