#!/usr/bin/env python
"""Ring the Conduit app — trigger an agent-initiated inbound call.

POSTs ``{base}/admin/ring/{agent}`` with the engine key. The engine sends a VoIP
push to the device that registered for that agent (the app's **Let this agent
call me** toggle must be on, which registers the token at
``/inbound/register/{agent}``). Default mode sends a credential-free push — the
app resolves the pairing endpoint after the user answers, so a declined ring
costs nothing. ``--inline`` provisions a room + token up-front and embeds them
in the push (the bot is dispatched before the answer).

Usage:
  uv run python scripts/ring.py --agent live
  uv run python scripts/ring.py --agent loopback --inline --base-url https://<host>

``--base-url`` defaults to ``PUBLIC_BASE_URL`` from ``.env``, else
``http://localhost:8000``. ``ENGINE_API_KEY`` is read from ``.env``. APNs setup
(the .p8 key etc.) lives on the engine — see docs/inbound-calls on the docs site.
"""

from __future__ import annotations

import argparse
import json
import ssl
import sys
import urllib.error
import urllib.request
from pathlib import Path

# Make the project root importable so we reuse the same .env-backed settings.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app.config import settings  # noqa: E402

# Verify TLS against certifi's CA bundle — same rationale as scripts/provision.py.
try:
    import certifi

    _SSL_CONTEXT: ssl.SSLContext | None = ssl.create_default_context(cafile=certifi.where())
except Exception:
    _SSL_CONTEXT = None


def _post_ring(base_url: str, agent: str, inline: bool, transport: str | None):
    settings.require("engine_api_key")
    url = base_url.rstrip("/") + f"/admin/ring/{agent}"
    body: dict = {"inline": inline}
    if transport:
        body["transport"] = transport
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
        help="Transport for --inline provisioning (default: the agent's own).",
    )
    parser.add_argument(
        "--base-url",
        default=settings.public_base_url or "http://localhost:8000",
        help="Dispatcher base URL (default: PUBLIC_BASE_URL or http://localhost:8000).",
    )
    parser.add_argument("--json", action="store_true", help="Print the raw payload instead.")
    args = parser.parse_args()

    status, body = _post_ring(args.base_url, args.agent, args.inline, args.transport)
    if status != 200:
        print(f"HTTP {status}")
        print(json.dumps(body, indent=2) if isinstance(body, dict) else body)
        if hint := _HINTS.get(status):
            print(f"\n⚠️  {hint}")
        sys.exit(1)

    if args.json:
        print(json.dumps(body, indent=2))
        return

    print(f"\nRinging '{args.agent}' (call_id {body['call_id']}, {body['mode']} mode)")
    print("APNs accepted the push — the device should be ringing now.")
    if body["mode"] == "inline":
        print("NOTE: inline mode already dispatched the bot; a decline leaves it")
        print("running until the pipeline timeouts reap it.")


if __name__ == "__main__":
    main()
