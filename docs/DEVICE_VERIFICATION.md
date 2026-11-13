# Device Verification Run Sheet

The reusable by-hand checklist for everything the simulator cannot run: real
CallKit calls, two-way WebRTC audio, routing, VoIP-push rings, Siri dialing. It is
used for a before/after comparison around any change that touches the call stack
(first use: the call-engine extraction into a Swift package) and again after every
transport-SDK bump. Internal; not published on the docs site.

Transports are written out in full (Daily, LiveKit, SmallWebRTC) so they don't
collide with the row ids (`S1` is Siri, `L1` is links).

Two sheets live here. The **main sheet** (Before/After, rows O, I, S, L, M, B, N)
is the call-stack regression pass; its recorded run is the November 2026 one under
Results. The **0.2.0 sheet** (further down: rows K, H, R, P, T, DJ, C, G, X) covers
what the engine 0.2 adoption added and has **not been run**: every Result cell is
empty on purpose, and nothing in it may be quoted as verified until it is filled in.

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
  | grep --line-buffered -E 'teardown\.|bot\.|dispatch\.|inbound\.|apns\.|engine\.|ring\.|connect\.'
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
| `inbound.ring_status agent=<id> call_id=<id> status=<s>` | Receipt: `answered`, `declined`, `busy`, `suppressed_by_focus`, `unanswered` (ring timed out), `canceled` (withdrawn, or the agent left a pre-connected ring). |
| `ring.sent`, `ring.canceled`, `ring.cancel_refused`, `ring.cancel_unsupported`, `ring.preconnect_unsupported` | The ring tracker: a ring sent, withdrawn, refused (answered or ended first), or sent without a feature the device does not list. |
| `connect.ring_over` | A pre-connect `/connect` landed after its ring had ended; refused with 409, no room, no bot. |
| `bot.call_answered`, `bot.call_held`, `bot.call_resumed`, `bot.call_signal` | A call-control signal reached the agent. |
| `bot.ring_deadline`, `bot.ring_canceled`, `bot.cancel_refused` | A ring bot gave up waiting for the answer, was ended by a cancel, or refused one because it had seen the answer. |

### Send a ring

```bash
cd example-backend      # ENGINE_API_KEY comes from .env
uv run python scripts/ring.py --agent loopback --base-url https://<host>
uv run python scripts/ring.py --agent live --base-url https://<host>
# credentials in the push (provisions a room, dispatches the bot before answer):
uv run python scripts/ring.py --agent live --inline --transport livekit --base-url https://<host>
```

Ring options for the 0.2.0 sheet (each is sent only to a device that registered the
matching push feature, and `ring.py` prints what it did):

```bash
uv run python scripts/ring.py --agent live --ring-timeout 15 --base-url https://<host>      # ring for 15 s (minimum 10)
uv run python scripts/ring.py --agent live --preconnect credentials --base-url https://<host>
uv run python scripts/ring.py --agent tone --inline --preconnect media --transport livekit --base-url https://<host>
uv run python scripts/ring.py --agent live --cancel-after 8 --base-url https://<host>       # ring, wait 8 s, withdraw
uv run python scripts/ring.py --agent live --cancel <call_id> --base-url https://<host>
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

The Debug build appends timestamped lines (ISO 8601, fractional seconds) to
`Documents/conduit-call-trace.log` in the app container
(`Conduit/Debug/CallTrace.swift`, `CallTraceObserver.swift`). It starts at **launch**,
including the cold launch a VoIP push causes, and is **not truncated per call**:

- `launch`, then `transport made: <kind> canConnectWhileRinging=<bool>` each time a
  transport is built.
- The call host's view: `ring: call=... known=... preconnect=... inline=...
  transport=...`, `state: <old> -> <new>`, `ring preparation: <old> -> <new>` (every
  phase, so fast ones are not lost), `cue: ...`, `spoken: connecting (answered, still
  connecting)`, `record: ...` (outcome, failure and missed reason, duration),
  `voip token: invalidated`.
- The engine's observable state: `hold: on|off` (always off: the app leaves the engine's hold off), `audio activated: true|false` (as the
  engine counts it; an activation it ignores, such as one during an unanswered ring,
  does not show), `interruption: began|ended`, `muted: true|false`.
- Every log event of the engine package, prefixed `engine <category> <level>:`
  (including CallKit's raw audio activations), which still also reach Console.
- While the in-call screen is up, one `screen: state=... muted=... onHold=...
  audioActivated=... selected=... activeRoute=[...] devices=[...]` line per change
  (polled every 250 ms), and `in-call screen shown`.
- Cue Lab presses and session snapshots.

Constraints:

- **The file is kept across launches** and moved to
  `conduit-call-trace.previous.log` at the next launch once it passes about 2 MB, so
  pull **both** files when a row's lines may be in the older one. Because rows run
  into each other, **write down the wall-clock time you start each row**, and pull
  the file right after the key rows.
- Nothing is written until the live environment starts, so the trace exists only in
  Debug builds.

```bash
BUNDLE_ID=$(awk -F'= *' '/^APP_BUNDLE_IDENTIFIER/{print $2}' Config/local.xcconfig)
RUN=/tmp/conduit-verify/before        # or /after, or /v020
xcrun devicectl device copy from --device "<device name or UDID>" \
  --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
  --source Documents/conduit-call-trace.log \
  --destination "$RUN/trace-<row>-<transport>.log"
# and, if it exists, Documents/conduit-call-trace.previous.log the same way
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
| O4b | A call starts on the earpiece (Daily, LiveKit, SmallWebRTC) | Nothing connected (AirPods off, no car). Place an outgoing call on each transport and hold the phone to your ear; once connected, switch to the speaker in the app; then airplane mode on for 10 s and off. Repeat on LiveKit with the native audio button instead of the in-app picker. | The call starts on the earpiece and stays there through connecting: the in-call picker shows Receiver, and the trace shows no `setAudioDevice` by the engine before your switch. *Record* whether the ringback and the spoken cues ("Connected", and on an answered call "Connecting") are audible at the ear on each transport. After your switch to the speaker, the sound stays on the speaker through the reconnect. | | |
| O4c | Ringback method A/B (done, iPhone 17, iOS 27.0; the DEBUG switch is gone) | Recorded result. Each method on Daily and LiveKit, with AirPods (Bluetooth HFP) and with nothing connected (phone at the ear). | *Earpiece:* the system sound is audible, quiet, fine; the audio player is inaudible even at full volume (the trace showed `play()` returned true, player volume 0.5, session output volume 1.0, route Receiver, about 1.7 s of playing). *AirPods:* the system sound is far too loud (it uses the ringer volume, not the call volume), and on LiveKit it jumps in level partway through the ring; the audio player is audible, steady, at call volume. *Speaker:* the system sound is audible (earlier tests); the audio player was not tried. On AirPods the player's `play()` returned 0.3 to 1.6 s after the ring was asked to start, once leaving 15 ms of ring before a LiveKit call connected. Neither method is right on every route, so the app now picks by route (O4e). | n/a | done |
| O4d | SmallWebRTC keeps its route | Over the hotspot LAN: place a SmallWebRTC call with nothing connected (phone at the ear); once connected switch to the speaker in the app and back to the receiver. Then a call with AirPods connected; then connect AirPods mid-call on an earpiece call, and take them out. Then airplane mode on for 10 s and off. Pull the trace. | The call starts on the earpiece (or the AirPods) and stays there through connecting. Trace (`smallwebrtc route:`): `route at activation: Receiver -> keep earpiece`, `join: route Receiver -> preferred audio device earpiece`, `preferred audio device -> earpiece`, then `joined: SDK selected earpiece, route Receiver` (with AirPods: `BluetoothHFP` and `bluetooth`). When the join comes before the activation the reason reads `the call's route before activation`. No line shows `route Speaker` unless you chose the speaker. The in-app picker moves the call; a reconnect logs `join: …` again for its new client and keeps the route. *Record* the route after AirPods connect mid-call (`devices now …: preferred audio device earpiece -> bluetooth`) and after they go. | | |
| O4e | The ringback follows the route (Daily, LiveKit) | Set the call volume to about half. Place an outgoing call with nothing connected (phone at the ear); then one with AirPods connected; then one from the ear where you switch to the speaker in the app while it rings; then one where you connect AirPods while it rings. On one AirPods call, try the volume buttons while it rings. Pull the trace. | *Earpiece:* the ring is heard at the ear, as before. *AirPods:* the ring is heard at call volume, steady, and the volume buttons change it. *Switched to the speaker mid-ring:* the ring goes on with the system sound and is heard on the speaker; *AirPods connected mid-ring:* the ring keeps the system sound to the end (no second `chose` line in either; *record* how loud it is in the AirPods). Trace per call: `ringback: chose systemSound: route Receiver is the phone's own or another output (the ringer volume)` then `ringback (system sound): playing at the ringer volume` on the earpiece; on AirPods `ringback (audio player): player made in … ms` at the cue, `ringback: route BluetoothHFP at the activation; readying the audio player`, `ringback (audio player): prepareToPlay() returned true in … ms`, then `ringback: chose audioPlayer: route BluetoothHFP is a headset-type output (the call volume)` and `ringback (audio player): play() returned true in … ms, player volume 0.5`; at connected `ringback: stopped, method …`. *Record* the `prepareToPlay()` and `play()` times on AirPods (O4c saw 0.3 to 1.6 s from the start to `play()` returning); a `play()` that still takes most of a second once prepared is the Bluetooth link's, not the app's. A `ringback: waiting for CallKit's audio activation to choose a method` line means the activation came after the 0.5 s start. | | |
| O5 | Lock mid-call | Start a call, lock the phone, wait 30 s, look at the lock screen. | Audio continues both ways; lock screen shows the agent's name (and photo if linked to a contact) and a timer that matches the in-app one. | | |
| O6 | Reconnection (Daily, LiveKit) | (a) Find `room` in `dispatch.accepted`, send `/admin/disconnect` for it. (b) Separately, with a new call: airplane mode on for 5 s, then off. Pull the trace after each. | You hear "Retrying connection" (repeats about every 7 s while down), then "Connected", and audio resumes with no input from you; the call is still one call. Engine shows `teardown.human_left` then `grace_started` then `grace_cancelled` or `human_joined`, never `grace_expired`. For (b) on both Daily and LiveKit, expect "Disconnected" within a second or two of airplane mode on (Daily infers it from the network path, LiveKit from its SDK), then "Retrying connection", then "Connected" soon after airplane mode off; if "Connected" is heard but audio stays silent for more than a few seconds, record it (Daily announces recovery when the path returns, before its media resumes). After the call is back you can talk at once, while "Connected" plays: the trace shows `cue: moment(reconnected)` with no `mic withheld: true` after it and no "mic was still withheld" warning. "Connected" is heard within about 1.5 s of the call being back or not at all (the trace then shows `speech: connected not started within 1.5 seconds; cutting off`), and no "Retrying connection" is heard once the call is back. *Record* the `speech:` lines from `request connected` to `didFinish connected` (or the cut-off) for each recovery. TODO(verify): what the app does after the bot is killed by `/admin/disconnect` (re-pair vs. end); record the observed behavior. | | |
| O6b | A long LiveKit outage | On LiveKit, airplane mode on for 35 to 45 s mid-call, then off; repeat once. Pull the trace. | "Disconnected", then "Retrying connection" about every 7 s, never two queued back to back. On recovery: no further "Retrying connection"; "Connected" within about 1.5 s or not at all; you can talk at once. The trace shows `speech: cut off retrying` (or nothing pending) before `speech: request connected`, then `didStart`/`didFinish connected` or `connected not started within 1.5 seconds; cutting off`, and no "mic was still withheld" warning. *Record* the times between `request connected`, `didStart` and `didFinish`. | | |
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

## Run sheet: engine 0.2.0 (pending, not yet run)

**Status.** Everything this sheet covers (a phone call ending the call, pre-connect while ringing, ring
timeouts and cancel pushes, call-control signals, engine-driven spoken cues, the
join deadline and "Agent didn't join", the explicit microphone request, the Cue Lab,
the Daily ring join, the rebuilt SmallWebRTC adapter, and the SDK bumps to
Pipecat 1.3.0, Daily 0.41.0 and LiveKit 2.19.0) is built and unit-tested; **device
verification pending**. It is built from the package's own device checklist
(`ConduitCallEngine/Docs/IntegrationGuide.md`, section 13) plus the app-level checks
the commits since the November run imply. The November record under Results is the
baseline: **a row that passed there and fails here is a regression**; a row that is
new has no baseline.

How to use it:

- One **Result** column, left empty: `P`, `F` + a one-line note, `-` (not run) or
  `n/a`. Rows marked *record* have no pass/fail; write down what happened.
- Same environment rules as the main sheet (one phone, one iOS version, one backend
  deployment, Debug build), plus the setup below. Record the build SHA, the package
  version resolved in `Package.resolved`, and the backend commit in the results block.
- Ids are new so they do not collide with the main sheet's: **K** build and
  permissions, **H** a phone call during a call, **R** missed rings, timeouts and cancels, **P** pre-connect,
  **T** the tone agent (audio-leak checks), **DJ** the Daily ring-join experiment
  (concluded), **W** incoming calls ready when the user picks up ("when they pick up"),
  **C** cues and the Cue Lab, **G** the join deadline, **X** regression calls on the
  new SDKs.
- Pull the call trace (see above) after the key rows; for the rows that are about
  what is audible, the trace shows what the app did, and you are the microphone.

### Setup for this sheet

| Piece | Notes |
|---|---|
| Backend | The reference engine from the commit under test, on pipecat-ai 1.4.0, with the `APNS_*` vars, Daily and LiveKit keys and the registry on a volume. It has the `tone` agent, the ring tracker and the cancel endpoint. |
| `tone` agent | An app agent on **LiveKit** pointing at `https://<host>/connect/tone`, and one on **Daily** pointing at the same URL, both with "Let this agent call me" on and the registration endpoint `https://<host>/inbound/register/tone`. The registry is keyed by engine agent id and the latest registration wins, so register **one at a time**: re-save the agent you want to ring (this re-registers) before each T and DJ row, and use `--transport` to match it. The tone is 440 Hz from the moment a human joins the room; it ignores client-ready, `call-connected` and hold, which is what makes it a leak detector. |
| Second phone | Another phone that can call the test phone's number (H rows). |
| AirPods or a car | For route checks (X rows, C rows). |
| Registrations | The Daily and LiveKit agents of the main sheet, inbound on, registered by this build (so the engine stores `push_features`). A registration made by the November build has none, and the engine then sends no `ring_timeout`, `preconnect` or cancel push to it: that is itself a check (R1). |
| Console | Attached to the phone, filtered to the app. The Debug build also routes the engine's log into the trace. |

### K. Build, permissions, SDKs

| # | Check | Steps | Pass when | Result |
|---|---|---|---|---|
| K1 | Bundle check on the new SDKs | `scripts/check-bundle.sh <path to the built Conduit.app>`; `ls "$APP/Frameworks"`. | The script passes; no stasel `WebRTC.framework`; no second un-prefixed WebRTC next to Daily's (this is the Pipecat 1.3.0 / Daily 0.41.0 / LiveKit 2.19.0 bundle). | |
| K2 | Install over the November build | Install this build over the November one without deleting the app (as M1). Launch. | Agents, keys, Recents history, linked contacts and inbound toggles are intact; old Recents rows read as before. | |
| K3 | Microphone prompt, first call | On an install where the microphone is undecided (delete the app, or reset in Settings), tap Call on an agent. | The system prompt appears **before** a call is placed; Allow places the call and the agent hears you. | |
| K4 | Microphone denied | With access denied (Settings, Apps, Conduit, Microphone off), tap Call. | No CallKit call appears; an alert "Microphone Access Needed" explains and its Settings button opens Settings; turning it on and calling again works. | |
| K5 | Microphone and the inbound toggle | On an undecided install, Edit an agent and turn on "Let this agent call me". Then repeat on a denied install, and once via an `--inbound` pairing QR (L1). | Turning it on prompts; after Deny a note under the toggle reads "Microphone access is off, so this agent won't hear you when it calls." and saving still works; the QR's prefilled sheet prompts when it appears. | |
| K6 | First inbound call, microphone decided | With the microphone allowed, kill the app, lock the phone, ring and answer. | Two-way audio from the lock screen; the agent hears you. | |
| K7 | Release-like build | Install a Release build (TestFlight or a local Release install) and ring it through production APNs. | Settings has no Debug section; no `conduit-call-trace.log` is written; the ring arrives and the call connects. | |
| K8 | Registration carries features | Save an inbound agent; read the engine log. | `inbound.registered` appears; then `ring.py --ring-timeout 15 --preconnect media` produces no `ring.preconnect_unsupported` or `ring.ring_timeout_unsupported` in the engine log (those appear only for a registration without the features). | |

### H. A phone call during a call

The app leaves the engine's call hold off (`supportsHolding: false`), so a phone
call the user accepts or places **ends** the Conduit call, as on 0.1 (O10 in the
November run). These rows confirm that it ends cleanly on each transport. Run each
on Daily, LiveKit and SmallWebRTC.

| # | Check | Steps | Pass when | Result |
|---|---|---|---|---|
| H1 | A phone call accepted ends the call | On a connected call, have the second phone call the test phone, and accept. Talk a few seconds, hang up. Then place a new Conduit call to the same agent. Pull the trace. | iOS offers to end the Conduit call and accept (no Hold & Accept). The Conduit call ends cleanly: trace `state: connected -> ended(completed)` and no `hold: on`; engine log `bot.end_call_signal` and `teardown.end_now reason=client-end-call` (SmallWebRTC may show `reason=client-left`) within about a second, no `grace_expired`; one **Completed** row in Recents; no "On Hold" anywhere. The phone call has normal audio. The new Conduit call connects with two-way audio. | |
| H2 | A phone call placed ends the call | During a connected Conduit call, place a call from the Phone app. | As H1: the Conduit call ends cleanly with one Recents row, and the phone call goes through. | |
| H3 | A declined phone call | On a connected call, have the second phone call the test phone and decline it. | The Conduit call carries on; *record* whether the in-call status shows "Paused" while it rings and that the agent hears you afterwards. | |
| H4 | Car or Bluetooth head unit | If you have one: place, take and end calls from the head unit, and accept a phone call during one. | Calls place and end; the phone call ends the Conduit call as in H1. *Record.* | |

#### Recorded: the engine's experimental hold (iPhone 17, iOS 27.0, November 2026)

Run on a build that turned the engine's hold on, before it was cut from the
release; kept for the follow-up in [ROADMAP](./ROADMAP.md) ("Hold for a real phone
call"). Not a row to run.

- **In-app hold and resume, no other call:** restored two-way audio on Daily and on
  LiveKit, every time it was tried.
- **Hold for a real phone call:** iOS held the engine's call; when the phone call
  ended the engine resumed it and CallKit reported `didActivate`; the session read
  `PlayAndRecord` / `VoiceChat`; no audio returned in either direction, on either
  transport, after several fix rounds. LiveKit: `setEngineAvailability(.default)`
  failed with `LiveKitError` code 801, "Audio engine returned error code: -4010", on
  every attempt for at least six seconds (the engine's three re-attaches and the
  experimental restarts L-B and L-C included); once CallKit's activation arrived
  5.4 s after the resume. Daily: no error, audio simply absent; a second in-app
  hold/resume and a route change did not help. iOS never delivered an
  interruption-ended notification.
- **One run each, not conclusions:** Daily candidate C (leave without the end-call
  signal, release the client, rejoin the same room on a fresh client) restored
  two-way audio once ("Disconnected", then "Connected", then the echo). The LiveKit
  candidates (restart the audio engine at once; after a pause with retries; tell
  WebRTC's audio session it was activated, then restart) all failed with -4010. The
  session-level candidates (re-apply the category, explicitly activate the session)
  were not run.
- **Open question:** after the phone call ended, the system call screen still showed
  the call as on hold on both transports, while the engine and the app reported it
  not held. Untraced.

The candidates, their DEBUG picker and the sheet row that drove them are on the
`hold-recovery-experiments` branches.

### R. Missed rings, timeouts and cancels

| # | Check | Steps | Pass when | Result |
|---|---|---|---|---|
| R1 | Ring times out | App killed, locked. `ring.py --agent <id> --ring-timeout 15`, do not answer. Then ring with no `--ring-timeout` and time it. Then ring a registration made by the November build (no `push_features`). | The first ring stops after about 15 seconds: Recents has a red **Missed** row (no qualifier), a quiet notification arrives, the Phone app's Recents lists the call as missed, the engine logs `status=unanswered`. The second rings for the app's own 60 seconds. For the November registration `ring.py` sends no `ring_timeout` (the engine logs `ring.ring_timeout_unsupported`) and the ring lasts 60 seconds. | |
| R2 | The sender cancels a ring | `ring.py --agent <id> --cancel-after 8` with the phone locked (pairing mode), then `--cancel <call_id>` against a second ring. | The ring stops at the cancel; **Missed** row, quiet notification, `ring.canceled` in the engine log, `status=canceled`; the app keeps running and the next ring arrives normally. | |
| R3 | A cancel after the answer | Ring, answer, then `ring.py --agent <id> --cancel <call_id>`. | The engine refuses with 409 (`ring ended` after the receipt, `ring answered` if its ring bot saw the answer first); the call continues and the agent is not ended. | |
| R4 | Busy and Focus labels | Ring during a call (I5), and ring with a Focus on (I6). | Recents reads **Missed — on another call** and **Missed — Focus**; the notification text names the reason; `status=busy` / `suppressed_by_focus`. *Record* if Focus still does not filter on this iOS version. | |
| R5 | Declined and unknown rings | Decline a ring (I3); ring an agent deleted offline (I7, N3). | A declined ring reads **Declined**, not Missed; the unknown agent rings under the pushed name, ends gracefully, and the app is not killed. | |

### P. Pre-connect

Pairing mode unless the row says otherwise. Audio-leak checks use the `tone` agent
(section T); these rows are about what the app and backend do.

| # | Check | Steps | Pass when | Result |
|---|---|---|---|---|
| P1 | `credentials` tier | `ring.py --agent <id> --preconnect credentials` on each transport (SmallWebRTC over the LAN). Answer after about 10 seconds. | The engine logs `dispatch.accepted` for a `/connect` made during the ring, before the answer; the trace shows `ring preparation:` phases and no join; on answer the call joins with those credentials and connects, two-way audio. | |
| P2 | `media` tier per transport | `ring.py --agent <id> --preconnect media` on LiveKit, Daily and SmallWebRTC. | LiveKit and Daily join during the ring (the engine logs the device joining, `teardown.first_human`; Daily's engine log shows `Daily connect while ringing` and `Daily agent audio -> unsubscribed` before the join); SmallWebRTC does **not** (the trace shows `canConnectWhileRinging=false` and no join before the answer) and still connects on answer. | |
| P3 | Agent never joins | Ring with an agent whose bot never joins the room (a pipeline that crashes on start, or a bot you kill as soon as it is dispatched) with `--preconnect media`, and answer after 10 seconds. | The call stays connecting, with no ringback ("Connecting" once, a second after the answer); about 20 seconds later (30 from the device's join) the backend gets an ordinary answered credential request and the call connects to the agent it returns, or fails as "Agent didn't join". *Record* which. | |
| P4 | Hang up the instant it starts | LiveKit: decline a pre-connected ring the instant it starts ringing, and separately end an outgoing call the instant after placing it. | The engine log shows the device leaving (with `bot.end_call_signal` if it had joined); the device is never left in the room (no zombie `teardown.human_joined` after the hang-up). | |
| P5 | The ring ends unanswered | Decline a `media` ring; let another time out (`--ring-timeout 15`); cancel a third (`--cancel`). | Each time the agent gets `end-call` or sees the participant leave within a second; the ring bot ends; no audio and no orange microphone indicator remain on the phone. | |
| P6 | The agent leaves a ready ring | `ring.py --agent <id> --preconnect media` then `--cancel <call_id>` once the device has joined (in-band cancel: the engine ends the bot, no push). | The ring stops, **Missed** row, `canceled` receipt, no flash of a second incoming call. | |
| P7 | A long ring, locked | `--preconnect media` with no `--ring-timeout`, phone locked, answer at about 50 seconds. | The device stays in the room the whole ring (no `teardown.human_left` for it), and answering connects. | |
| P8 | Airplane mode during the ring | Start a `media` ring, turn airplane mode on for the ring, then off, then answer. | The ring keeps ringing; answering connects as without pre-connect. | |
| P9 | Time to first audio | Answer a `credentials` ring and a `media` ring, and a plain ring, each on LiveKit. | *Record* the seconds from answering to the agent's first audio in each case; pre-connect should not be slower. | |
| P10 | A failed preparation never ends the ring | Edit the agent's pairing key to a wrong value, ring with `--preconnect credentials`, wait 10 seconds, then answer. Restore the key afterwards. | The ring keeps ringing through the failed preparation; answering fails fast as "Authentication failed" (the answered request is refused too). | |
| P11 | A ring that was over before the request | Decline a `--preconnect credentials` ring the instant it appears. | The engine logs `connect.ring_over` if the request landed late; no room is made and no bot is dispatched. | |

### T. The tone agent: no audio before the answer

Register the `tone` agent for the transport under test (see Setup). Any tone while
the phone rings is a leak; after you answer it should be audible at once. Do each
with the app **killed** and the phone **locked**, and once unlocked with the app open.

| # | Check | Steps | Pass when | Result |
|---|---|---|---|---|
| T1 | LiveKit `media` ring | `ring.py --agent tone --inline --preconnect media --transport livekit`. Listen during the ring (phone speaker, then AirPods). | Nothing from the app is audible; the ringtone and vibration are unaffected; no orange microphone indicator; Console and the trace show no audio-session activation by the app before CallKit's `didActivate`; the engine logs the device joining the room. | |
| T2 | Answer the LiveKit ring | Answer T1's ring. | CallKit activates; the tone is heard within a second; `bot.call_answered` follows the activation; the route is right (AirPods when connected, speaker otherwise) and the in-app route picker works; "Connected" is heard (record whether in full). | |
| T3 | The tone after the ring ends | Decline a tone ring, let one time out, cancel one. | Silence from the phone; no microphone indicator; the tone bot ends. | |
| T4 | The tone on Daily and SmallWebRTC | Daily: `ring.py --agent tone --inline --preconnect media --transport daily`. SmallWebRTC (pairing only, over the LAN): `ring.py --agent tone --preconnect media`. | Daily joins during the ring, SmallWebRTC does not (its tier is lowered to `credentials`); no tone while ringing on either; the tone is heard at once after the answer. *Record* what SmallWebRTC does. | |

### DJ. Daily ring join (experiment, concluded)

Run on an iPhone 17 (iOS 27.0, phone locked, app not running unless stated) with the
DEBUG picker this section used to describe, now removed. D1 (default subscriptions
during the ring): after the answer no agent audio for the whole call, and the route
flipped between speaker and earpiece four times in 2.5 s; **fails**. D2 (agent audio
unsubscribed from before the join until the first attach): Daily accepted the
unsubscribe before the join; a 20 s ring with no audio activity; at the answer
CallKit activated audio, the adapter subscribed, the agent played cleanly and the
route settled within about 0.3 s; repeated with a cold launch by the push and an
answer 0.7 s after the agent was ready, the same; **passes**. D3 (staged instead of
unsubscribed): three rings, the same sequence in the trace, the route longer on the
earpiece after the answer (up to 1.35 s); no advantage. The package now joins Daily
during a `media` ring with D2's method (P2, T4, W). Still open: other devices,
Bluetooth and CarPlay routes, and a ring of about 50 s (P7 on Daily).

### C. Cues and the Cue Lab

The spoken cues were inaudible during Daily calls and in the last retry phase of a
LiveKit outage on the November run, cause unknown. The announcer's audio mechanism
has not changed; the Cue Lab (Debug builds, the magnifying-glass waveform button on the call screen)
exists to find out which playback paths are audible.

| # | Check | Steps | Pass when | Result |
|---|---|---|---|---|
| C1 | Cues on LiveKit | Outgoing call; then airplane mode on for 10 seconds and off; then for several minutes in a second call. Hang up while "Retrying connection" plays. | *Record* per cue and phase whether it was audible: ringback while connecting, "Connected" once at the activation, "Disconnected" once per outage, "Retrying connection" every 7 seconds, and the last retry phase. The loop stops with the call (no cue after hang-up). | |
| C2 | Cues on Daily | The same on a Daily agent. | *Record* the same. (Known inaudible in November.) | |
| C3 | Cues on SmallWebRTC | The same over the LAN. | *Record* the same. | |
| C4 | Cue Lab, LiveKit call | On a connected LiveKit call open the Cue Lab. Press 1, 2, 3, 4, 5, 6a, 6b, 7a, 7b one at a time, a few seconds apart, on the phone speaker; repeat on AirPods; flip the two ducking switches and press 7a again; tap "Log session now". | *Record* into the grid under Results which numbers were heard and from which output. The call's audio and microphone are unaffected, and the trace's session snapshots before and after each press show no change of category, mode or activation. | |
| C5 | Cue Lab, Daily call | The same on a Daily call (7a and 7b are disabled there). | *Record* into the grid. | |
| C6 | Cue Lab in the last retry phase | On a LiveKit call, airplane mode on until "Retrying connection" goes silent (about a minute), then press the candidates. | *Record* which numbers are heard in the phase where the normal cues were not. | |
| C7 | Cue Lab, SmallWebRTC call | The same on a SmallWebRTC call. | *Record* into the grid. | |
| C8 | The agent does not hear the connect sounds | On the phone speaker, call an echo agent (one that plays the caller's own voice back), on LiveKit and on Daily; then answer a ring from it, and a pre-connected (`--preconnect media`) ring on LiveKit. Stay silent until "Connected" has finished, then speak. Repeat with airplane mode on for 10 seconds mid-call. | No ringback and no "Connected" comes back from the agent, and your own voice does, from the first word after "Connected". The call screen never shows muted. The trace shows `mic withheld: true` at the ringback and `mic withheld: false` just after "Connected", with no "mic was still withheld" warning. After the outage, "Disconnected"/"Retrying" are not echoed either (the connection is down); the second "Connected" may be echoed, by design (the mic opens the moment the call is back), and the trace shows no `mic withheld: true` after `cue: moment(reconnected)`. *Record* any echoed cue and how long after "Connected" your first words were echoed. | |

### S. The connect sequence

On a call the user placed: the ringback starts half a second after dialing and the
call stays "Connecting" for at least 2.6 s, so the first tone plays in full; then
"Connected" with the mic closed; then the mic opens and the agent is sent
`call-connected`, which is when a reference agent greets. An answered call has no
ringback and no minimum (section W). Run against a backend
from this build (it reads `call_signals`) and an app agent re-saved with this build
(so its registration lists them). `tone` plays from the moment the device joins and
ignores every signal; `loopback` echoes once it is released.

| # | Check | Steps | Pass when | Result |
|---|---|---|---|---|
| S1 | Outgoing, fast agent | LiveKit `loopback` on the speaker: dial and say "one two three" continuously. | Nothing for about 0.5 s, then one full ring tone; the screen and the system call UI show connecting until the tone ends (about 2.6 s from dialing, not 1.2 s); then "Connected"; nothing of the ring, "Connected" or your words before it comes back to you; your voice echoes only after "Connected" finished. The backend logs `bot.call_signal signal=call-connected` once and `bot.call_connected via=signal`. | |
| S2 | Outgoing, the same on Daily | S1 on Daily. | As S1. The call starts on the earpiece on every transport now (the app makes no speaker change); switch to the speaker in the app for S1 and S2 if you want them on the speaker. | |
| S3 | Outgoing, tone agent | LiveKit `tone`, then Daily `tone`. | The tone is heard from about the device's join, under the ring (the tone agent ignores the signals by design); the call still shows connecting until the ring's tone ends. | |
| S4 | Answered ring | Moved to section W (W5). | | |
| S5 | Pre-connected ring | Moved to section W (W1 to W3). | | |
| S6 | Reconnect | During S1, airplane mode on for 10 s, then off. | "Disconnected", "Retrying connection", then "Connected" on return; the echo resumes as soon as the call is back (the mic is not withheld after a reconnect, so "Connected" itself may be echoed); the backend logs a second `bot.call_signal signal=call-connected` and no second `bot.call_connected`; the agent does not greet again. | |
| S7 | Hang up during the wait | Dial and hang up within 2 s. | No "Connected"; Recents shows a canceled call; the backend logs `client-end-call`. Hang up within 0.5 s: no ring tone at all. | |
| S8 | Older backend | S1 against a backend from before this build (it ignores `call_signals`). | The agent greets when the device joins, as before, possibly over the ring tone; the app works unchanged. | |

### W. Incoming calls ready when the user picks up

The backend from this build asks for the best pre-connect the registration takes on
every ring and starts the agent before the push (the ring response's `bot_in_room`
and `bot_wait_secs`); `--preconnect none` rings plainly and `--no-wait` pushes at
once. An answered call gets no ringback and no minimum connecting time: nothing from
the app when its agent was there at the answer; "Connecting" once if it is still
connecting a second after the answer, then "Connected" with the mic closed. Use
`loopback` (it echoes once it has `call-connected`) and `tone` (a tone from the
moment the device joins, whatever the signals). App killed and phone locked, then
once unlocked with the app open.

| # | Check | Steps | Pass when | Result |
|---|---|---|---|---|
| W1 | Ready at the answer, LiveKit | `ring.py --agent loopback --inline --transport livekit`; the response shows `preconnect: media` and `bot_in_room: true`; answer after about 3 s and talk. | Nothing from the app before or after the answer (no ringback, no "Connecting", no "Connected"); the call screen is connected at the answer; your voice comes back within about a second of the answer. Trace: `state: incomingRinging -> connected` at the answer, then `audio activated: true` and `cue: moment(connected)`, no `cue: start(connecting)`. Backend: `bot.call_signal signal=call-connected` within about a second of the answer. With `tone`: no tone during the ring, the tone at once after the answer. | |
| W2 | Ready at the answer, Daily | W1 with `--transport daily`. | As W1. Engine log: `Daily connect while ringing ...` and `Daily agent audio -> unsubscribed` before the join, then after the answer `Daily attach: agent audio wanted subscribed` and `Daily agent audio is subscribed` before `Daily client message call-connected sent`; the route settles within a fraction of a second. | |
| W3 | Ready at the answer, pairing mode | `ring.py --agent loopback` (pairing, default tier), on LiveKit and on Daily. | As W1. Backend: `ring.bot_wait outcome=joined` before `ring.sent`, and the app's `/connect` during the ring gets the prepared room (no second `dispatch.accepted`). | |
| W4 | Answered before the agent is there | `ring.py --agent tone --inline --transport daily --no-wait`, answer the instant it rings; repeat with `loopback` and on LiveKit. | No ringback. If the agent has not joined a second after the answer, "Connecting" once (trace: `spoken: connecting`). The call connects the moment the agent is in the room, with no extra 2.6 s: then "Connected"; with `loopback` your voice echoes only after "Connected" has finished; with `tone` the tone may start under "Connected". *Record* the seconds from the answer to the agent's audio. | |
| W5 | Plain ring | `ring.py --agent loopback --preconnect none` (pairing), answer. | No ringback; "Connecting" once if still connecting a second after the answer; "Connected", then the echo. *Record* the seconds from the answer to the echo, to compare with W3. | |
| W6 | A placed call is unchanged | S1 and S2. | As S1 and S2: ringback after 0.5 s, at least 2.6 s connecting, "Connected", then the echo. | |
| W7 | A slow agent does not hold the ring back | Ring an agent whose bot takes longer than 8 s to join (or set `RING_BOT_WAIT_SECS=2` on a test deployment). | The phone rings once the wait runs out (`bot_in_room: false`, `ring.bot_wait outcome=timeout`); answering connects when the agent arrives, as W4. | |

### G. The join deadline

| # | Check | Steps | Pass when | Result |
|---|---|---|---|---|
| G1 | Agent never joins | Call an agent whose bot never joins the room (a pipeline that crashes on start, or a bot you kill as soon as it is dispatched) on LiveKit and Daily. | After about 30 seconds of "Connecting" the call fails: the status reads "Agent didn't join" with the hint to check that the server starts the agent; Recents reads "Failed — agent didn't join"; the CallKit call ends; no call is left behind. | |
| G2 | A slow agent that does join | Call an agent that takes 10 to 20 seconds to become ready. | The call stays connecting and then connects; it does not fail. | |

### X. Regression calls on the new SDKs

Re-run these rows from the main sheet on this build, on all three transports where
the row says so, and record the result here. Use the November record as the baseline.

| # | Check | Steps | Pass when | Result |
|---|---|---|---|---|
| X1 | Outgoing, cold and warm | O1, O2, O3 (Daily, LiveKit, SmallWebRTC). | As the main sheet; two-way audio, mic indicator, mute in sync. Daily survives 60 seconds of talking. | |
| X2 | Routing and lock | O4, O5. | In-app picker moves audio on both Daily and LiveKit; the native route button moves it on LiveKit; the lock screen shows the name and a matching timer. | |
| X3 | Reconnection | O6, O7 on Daily and LiveKit; a SmallWebRTC drop (Wi-Fi off briefly). | O6 and O7 as before; after a long outage "Connected" is not announced while still offline and the call ends as "Failed — connection lost"; SmallWebRTC re-pairs to a fresh bot or ends. | |
| X4 | Hang-up and wrong key | O8, O9. | Immediate teardown on every hang-up (`teardown.end_now`); one Recents row per call; the wrong key fails as "Authentication failed". | |
| X5 | Inbound | I1 to I5, I8. | As the main sheet, with the new receipt statuses where they apply. | |
| X6 | Destructive rows last | I7, I9, then re-add the agent with L1. | As the main sheet. | |
| X7 | Siri, links, diagnostics | S1, S2, S3, L1, L2. | As the main sheet; Test Connection on LiveKit leaves no agent waiting out its grace window (`teardown.end_now` rather than `grace_expired`). | |
| X8 | Three transports, one launch | B2. | No crash; two-way audio on each; Daily survives past 60 seconds. | |
| X9 | SmallWebRTC rebuilt adapter | Call, hang up, call again at once; call and hang up within a second, three times; leave a SmallWebRTC call and call again without waiting. | Each call connects and ends cleanly; the engine logs `teardown.end_now` for each, with no stale session or second bot; no crash. | |
| X10 | Interruption | O10: Siri, then a cellular call. | Siri pauses the mic and it comes back; a cellular call now holds (H1) rather than ending the call. | |

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
| Call trace, 0.2.0 sheet | `trace-<row>-<transport>.log` plus `conduit-call-trace.previous.log` if present (at least H1, P2, T1, T2, DJ rows, C4 to C7, G1) | `ring preparation:` phases, `hold:` (always off), `audio activated:`, `cue:`, the engine's lines, the Cue Lab snapshots |
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

The engine 0.2.0 session is not yet recorded. Fill this block (and the grid under it)
when it runs; until then nothing from the 0.2.0 sheet is verified.

```text
Run:                 Engine 0.2.0 sheet (pending, not yet run)
Date:
Build SHA:
Engine package:      ConduitCallEngine 0.2.x (resolved version and revision from Package.resolved)
SDK versions:        Pipecat iOS client      Daily      LiveKit      SmallWebRTC fork revision
Build config:        Debug
iOS version:
Phone model:
Backend deployment:  (host, engine commit, pipecat-ai version, registry volume yes/no)
Agents used:         Daily=      LiveKit=      SmallWebRTC=      tone=
Network:             (Wi-Fi / hotspot / cellular)
Second phone / AirPods / car:
Artifacts dir:       /tmp/conduit-verify/v020/
Notes / surprises:
```

Cue Lab grid (C4 to C7): write `H` for heard, `-` for not heard, `?` for unclear, per
candidate and output.

| Candidate | Daily, speaker | Daily, AirPods | LiveKit, speaker | LiveKit, AirPods | LiveKit, last retry phase | SmallWebRTC, speaker |
|---|---|---|---|---|---|---|
| 1 Synth (app session) | | | | | | |
| 2 Synth (own session) | | | | | | |
| 3 Synth file (AVAudioPlayer) | | | | | | |
| 4 Synth buffer (AVAudioEngine) | | | | | | |
| 5 Ring (AVAudioPlayer) | | | | | | |
| 6a Ring (system sound) | | | | | | |
| 6b Ring (alert sound) | | | | | | |
| 7a LiveKit SoundPlayer speech | n/a | n/a | | | | n/a |
| 7b LiveKit SoundPlayer ring | n/a | n/a | | | | n/a |

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
