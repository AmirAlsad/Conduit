#!/usr/bin/env python
"""Register / list / delete the Daily direct-mode webhook.

Direct mode is webhook-driven: Daily calls ``POST {base}/webhooks/daily`` when a
human joins a registered room, and the engine dispatches a bot reactively. That
webhook is created through Daily's REST API — there is **no dashboard** for it.
This script is that registration.

It reads ``DAILY_API_KEY`` and ``DAILY_WEBHOOK_SECRET`` from your ``.env`` (via
``app.config``) and registers the webhook using that same secret as the ``hmac``,
so the value Daily signs with always matches what the dispatcher verifies with —
you can't accidentally register a mismatched secret.

Usage:
  uv run python scripts/daily_webhook.py register --base-url https://<host>
  uv run python scripts/daily_webhook.py list
  uv run python scripts/daily_webhook.py delete --uuid <uuid>

``--base-url`` is wherever YOUR dispatcher is publicly reachable:
  • local testing : your tunnel host  (e.g. https://abc.trycloudflare.com)
  • deployed      : your Railway URL  (e.g. https://conduit.up.railway.app)
The script appends ``/webhooks/daily``. ``register`` updates an existing webhook
for that exact URL in place (no duplicates).
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

EVENT_TYPES = ["participant.joined"]

# Verify TLS against certifi's CA bundle. The python.org / uv Python builds on
# macOS don't use the system cert store, so urllib otherwise fails to verify
# api.daily.co. Falls back to the default context if certifi isn't present.
try:
    import certifi

    _SSL_CONTEXT: ssl.SSLContext | None = ssl.create_default_context(cafile=certifi.where())
except Exception:
    _SSL_CONTEXT = None


def _request(method: str, path: str, body: dict | None = None):
    settings.require("daily_api_key")
    url = f"{settings.daily_api_url}{path}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        url,
        data=data,
        method=method,
        headers={
            "Authorization": f"Bearer {settings.daily_api_key}",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30, context=_SSL_CONTEXT) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, raw.decode(errors="replace")


def _webhook_url(base_url: str) -> str:
    return base_url.rstrip("/") + "/webhooks/daily"


def cmd_list(_args) -> None:
    status, body = _request("GET", "/webhooks")
    print(f"HTTP {status}")
    print(json.dumps(body, indent=2))


def cmd_delete(args) -> None:
    status, body = _request("DELETE", f"/webhooks/{args.uuid}")
    print(f"delete: HTTP {status}")
    print(json.dumps(body, indent=2))


def cmd_register(args) -> None:
    settings.require("daily_webhook_secret")
    target = _webhook_url(args.base_url)

    # Update in place if a webhook for this exact URL already exists (avoid dupes,
    # which would double-fire — harmless thanks to idempotent dispatch, but noisy).
    status, existing = _request("GET", "/webhooks")
    existing_uuid = None
    if status == 200 and isinstance(existing, list):
        for wh in existing:
            if wh.get("url") == target:
                existing_uuid = wh.get("uuid")
                break

    payload = {
        "url": target,
        "eventTypes": EVENT_TYPES,
        "hmac": settings.daily_webhook_secret,
    }
    if existing_uuid:
        status, body = _request("POST", f"/webhooks/{existing_uuid}", payload)
        action = "updated"
    else:
        status, body = _request("POST", "/webhooks", payload)
        action = "created"

    print(f"{action}: HTTP {status}")
    print(json.dumps(body, indent=2))

    if status not in (200, 201):
        print("\n⚠️  Registration failed. Most common causes:")
        print("  • --base-url isn't publicly reachable, or the dispatcher isn't running")
        print("    (Daily probes the URL and requires a 200 before it will register).")
        print("  • Webhooks aren't enabled on the Daily account (requires a credit card).")
        sys.exit(1)

    print(f"\n✅ Direct mode armed. Daily will POST {target} on participant.joined.")


def main() -> None:
    parser = argparse.ArgumentParser(description="Manage the Daily direct-mode webhook.")
    sub = parser.add_subparsers(dest="cmd", required=True)

    reg = sub.add_parser("register", help="Create/update the participant.joined webhook")
    reg.add_argument(
        "--base-url",
        required=True,
        help="Public base URL of the dispatcher (tunnel host or Railway URL).",
    )
    reg.set_defaults(func=cmd_register)

    lst = sub.add_parser("list", help="List existing webhooks (and their hmac).")
    lst.set_defaults(func=cmd_list)

    dele = sub.add_parser("delete", help="Delete a webhook by uuid.")
    dele.add_argument("--uuid", required=True)
    dele.set_defaults(func=cmd_delete)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
