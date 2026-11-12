#!/usr/bin/env python
"""Ring the Conduit app — trigger an agent-initiated inbound call.

POSTs ``{base}/admin/ring/{agent}`` with the engine key. The engine sends a VoIP
push to the device that registered for that agent (the app's **Let this agent
call me** toggle must be on, which registers the token at
``/inbound/register/{agent}``). Default mode sends a credential-free push — the
app resolves the pairing endpoint after the user answers, so a declined ring
costs nothing. ``--inline`` provisions a room + token up-front and embeds them
in the push (the bot is dispatched before the answer). The push also carries the
caller ``display_name`` (and ``handle``) the app registered, when it sent them;
the script prints the name it rang as.

``--ring-timeout N`` shortens the ring (the app clamps it to at least 10 s); the
engine sends it only to a device that registered the ``ring_timeout`` push
feature. Every ring asks the app to prepare during the ring (pre-connect): by
default the best tier the device's registration takes (``media`` when it lists
the ``preconnect`` push feature and the ``call-connected`` call signal,
``credentials`` with only the feature, none without it). ``--preconnect
credentials|media`` asks for one tier (``media`` is sent as ``credentials`` to a
device without ``call-connected``); ``--preconnect none`` sends a plain ring.

Agent first: when the ring starts its agent before the push (``--inline``, and a
pre-connected pairing ring, whose room the engine prepares for the app's request
during the ring), the engine pushes once the agent's bot is in the room, or after
``RING_BOT_WAIT_SECS`` (8) without it; the script prints how long that took.
``--no-wait`` pushes at once and prepares nothing for a pairing ring.

``--cancel CALL_ID`` withdraws a ring that is still ringing (no new ring);
``--cancel-after SECONDS`` rings, waits, then cancels that ring. A cancel push
goes only to a device that registered the ``cancel`` push feature; otherwise the
engine refuses it (409) unless the agent can leave a pre-connected room instead.

Usage:
  uv run python scripts/ring.py --agent live
  uv run python scripts/ring.py --agent loopback --inline --base-url https://<host>
  uv run python scripts/ring.py --agent tone --inline --preconnect media --ring-timeout 30
  uv run python scripts/ring.py --agent live --preconnect none --no-wait
  uv run python scripts/ring.py --agent live --cancel-after 8
  uv run python scripts/ring.py --agent live --cancel <call_id>

``--base-url`` defaults to ``PUBLIC_BASE_URL`` from ``.env``, else
``http://localhost:8000``. ``ENGINE_API_KEY`` is read from ``.env``. APNs setup
(the .p8 key etc.) lives on the engine — see docs/inbound-calls on the docs site.
"""

from __future__ import annotations

import argparse
import json
import ssl
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

# Make the project root importable so we reuse the same .env-backed settings.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app.config import settings  # noqa: E402
from app.rings import CANCEL_ANSWERED, CANCEL_UNSUPPORTED  # noqa: E402

# Verify TLS against certifi's CA bundle — same rationale as scripts/provision.py.
try:
    import certifi

    _SSL_CONTEXT: ssl.SSLContext | None = ssl.create_default_context(cafile=certifi.where())
except Exception:
    _SSL_CONTEXT = None


def ring_body(
    *,
    inline: bool,
    transport: str | None = None,
    ring_timeout: int | None = None,
    preconnect: str | None = None,
    wait_for_bot: bool = True,
) -> dict:
    """The /admin/ring body; options left unset are omitted (the engine's defaults)."""
    body: dict = {"inline": inline}
    if transport:
        body["transport"] = transport
    if ring_timeout is not None:
        body["ring_timeout"] = ring_timeout
    if preconnect:
        body["preconnect"] = preconnect
    if not wait_for_bot:
        body["wait_for_bot"] = False
    return body


def _post(base_url: str, path: str, body: dict):
    settings.require("engine_api_key")
    url = base_url.rstrip("/") + path
    req = urllib.request.Request(
        url,
        data=json.dumps(body).encode(),
        method="POST",
        headers={
            "Authorization": f"Bearer {settings.engine_api_key}",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30, context=_SSL_CONTEXT) as r:
            return r.status, json.loads(r.read())
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, raw.decode(errors="replace")
    except urllib.error.URLError as e:
        print(f"Could not reach {url}: {e.reason}", file=sys.stderr)
        print("Is the dispatcher running? (uv run uvicorn app.main:app)", file=sys.stderr)
        sys.exit(1)


_HINTS = {
    401: "Bearer rejected — does ENGINE_API_KEY in .env match the deployed engine's?",
    404: (
        "Unknown agent, or no VoIP registration yet — check the --agent name and that "
        "\"Let this agent call me\" is enabled in the app (with the registration URL "
        "pointing at /inbound/register/<agent>)."
    ),
    502: "APNs rejected the push — see `reason` and `hint` above.",
    503: "Engine missing APNs (or transport) config — set the APNS_* vars on the engine.",
}

_RING_HINTS = {
    409: "The ring was canceled, or got a receipt, while the engine waited for its "
    "agent to join the room, so its push never went out.",
}

_CANCEL_HINTS = {
    404: "The engine doesn't know that call_id for this agent (wrong agent, or the "
    "engine restarted since the ring — rings are tracked in memory).",
    409: "The ring is already over (its receipt arrived) or was already canceled.",
}

_CANCEL_UNSUPPORTED_HINT = (
    "The device's app doesn't list the `cancel` push feature (an older build), so "
    "a cancel push would flash a call there. The ring was left ringing; it ends "
    "when it times out or the user declines."
)


_CANCEL_ANSWERED_HINT = (
    "The user already answered (the agent saw it before the app's receipt "
    "arrived), so nothing was withdrawn and the call is live."
)


def _fail(status: int, body, hints: dict) -> None:
    print(f"HTTP {status}")
    print(json.dumps(body, indent=2) if isinstance(body, dict) else body)
    if hint := hints.get(status) or _HINTS.get(status):
        print(f"\n⚠️  {hint}")
    sys.exit(1)


def _cancel(base_url: str, agent: str, call_id: str, as_json: bool) -> None:
    status, body = _post(base_url, f"/admin/ring/{agent}/cancel", {"call_id": call_id})
    if status != 200:
        detail = body.get("detail") if isinstance(body, dict) else None
        if isinstance(detail, dict) and detail.get("reason") == CANCEL_UNSUPPORTED:
            _fail(status, body, {status: _CANCEL_UNSUPPORTED_HINT})
        if isinstance(detail, dict) and detail.get("reason") == CANCEL_ANSWERED:
            _fail(status, body, {status: _CANCEL_ANSWERED_HINT})
        _fail(status, body, _CANCEL_HINTS)
    if as_json:
        print(json.dumps(body, indent=2))
        return
    if body["method"] == "in_band":
        print(f"Canceled {call_id} in band: the agent left the pre-connected room (no push).")
    elif body["method"] == "before_push":
        print(f"Canceled {call_id} before its push went out: nothing reached the phone.")
    else:
        print(f"Canceled {call_id} with a cancel push (APNs {body['apns_status']}).")
    if body["bot_ended"]:
        print("The ring's bot was ended.")


def main() -> None:
    parser = argparse.ArgumentParser(description="Ring the Conduit app (inbound VoIP call).")
    parser.add_argument("--agent", default="loopback", help="Agent id (default: loopback).")
    parser.add_argument(
        "--inline",
        action="store_true",
        help="Embed room credentials in the push (provisions + dispatches the bot now).",
    )
    parser.add_argument(
        "--transport",
        choices=["daily", "livekit"],
        help="Transport of the room made at ring time (--inline, or a pre-connected "
        "pairing ring). Default: the one the app registered for its agent; with none "
        "registered (an older app) a pairing ring prepares nothing and --inline uses "
        "the agent's default.",
    )
    parser.add_argument(
        "--ring-timeout",
        type=int,
        metavar="SECONDS",
        help="Shorten this ring (the app clamps it to at least 10 s and its own maximum).",
    )
    parser.add_argument(
        "--preconnect",
        choices=["credentials", "media", "none"],
        help="Ask the app to prepare while ringing: fetch credentials, or also join "
        "the room (the bot then waits for the answer); none for a plain ring "
        "(default: the best the device's registration takes).",
    )
    parser.add_argument(
        "--no-wait",
        action="store_true",
        help="Push at once instead of when the agent is in the room (a pairing ring "
        "then prepares nothing; its agent starts when the app asks).",
    )
    cancel = parser.add_mutually_exclusive_group()
    cancel.add_argument(
        "--cancel",
        metavar="CALL_ID",
        help="Withdraw a ring that is still ringing instead of ringing (ring options are ignored).",
    )
    cancel.add_argument(
        "--cancel-after",
        type=float,
        metavar="SECONDS",
        help="Ring, wait this long, then cancel the ring.",
    )
    parser.add_argument(
        "--base-url",
        default=settings.public_base_url or "http://localhost:8000",
        help="Dispatcher base URL (default: PUBLIC_BASE_URL or http://localhost:8000).",
    )
    parser.add_argument("--json", action="store_true", help="Print the raw payload instead.")
    args = parser.parse_args()

    if args.cancel:
        _cancel(args.base_url, args.agent, args.cancel, args.json)
        return

    body = ring_body(
        inline=args.inline,
        transport=args.transport,
        ring_timeout=args.ring_timeout,
        preconnect=args.preconnect,
        wait_for_bot=not args.no_wait,
    )
    status, body = _post(args.base_url, f"/admin/ring/{args.agent}", body)
    if status != 200:
        _fail(status, body, _RING_HINTS)

    if args.json:
        print(json.dumps(body, indent=2))
        if args.cancel_after is not None:
            time.sleep(args.cancel_after)
            _cancel(args.base_url, args.agent, body["call_id"], args.json)
        return

    print(f"\nRinging '{args.agent}' (call_id {body['call_id']}, {body['mode']} mode)")
    if name := body.get("display_name"):
        print(f"Rang as: {name}")
    else:
        print("No caller name: this registration predates names, so the app will show its own.")
    print("APNs accepted the push — the device should be ringing now.")
    sent = body.get("preconnect")
    if args.preconnect == "none":
        print("Pre-connect: none (opted out), a plain ring.")
    elif args.preconnect is None and sent is not None:
        print(f"Pre-connect: {sent} (the best the device's registration takes).")
    elif sent is None:
        print("Pre-connect not sent: the device's app doesn't list the preconnect")
        print("push feature, so it rings as a plain ring (no ring bot).")
    elif sent != args.preconnect:
        print(f"Pre-connect sent as {sent}: the device's app doesn't list")
        print("the call-connected call signal, which a media ring needs.")
    else:
        print(f"Pre-connect requested: {args.preconnect}.")
    waited = body.get("bot_wait_secs")
    if body.get("bot_in_room") is True:
        print(f"Agent first: its bot joined the room {waited:g} s after it started;")
        print("then the push went out.")
    elif body.get("bot_in_room") is False:
        print(f"Agent first: its bot was not in the room after {waited:g} s; rang anyway.")
    if args.ring_timeout is not None and "ring_timeout" in body and body["ring_timeout"] is None:
        print("Ring timeout not sent: the device's app doesn't list the ring_timeout")
        print("push feature, so it rings for its own default.")
    if body["mode"] == "inline":
        print("NOTE: inline mode already dispatched the bot; it ends on a decline")
        if sent:
            print("(or any receipt but answered) and when the ring deadline passes.")
        else:
            print("(or any receipt but answered).")
    elif body.get("bot_in_room") is not None:
        print("NOTE: the engine prepared the room and bot at ring time; the app's credential")
        print("request during the ring takes them. The bot ends on a decline (or any receipt")
        print("but answered), when the ring deadline passes, or if the app answers without them.")
    if args.cancel_after is not None:
        print(f"Canceling in {args.cancel_after:g} s…")
        time.sleep(args.cancel_after)
        _cancel(args.base_url, args.agent, body["call_id"], args.json)
    else:
        print(f"To withdraw it: scripts/ring.py --agent {args.agent} --cancel {body['call_id']}")


if __name__ == "__main__":
    main()
