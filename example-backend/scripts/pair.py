#!/usr/bin/env python
"""Print a conduit:// pairing link (and a scannable QR) for an agent.

The Conduit app registers the ``conduit://`` URL scheme: scanning the QR with
the iPhone Camera app (or opening the link on the device) opens a pre-filled
Add Agent sheet — name, transport, pairing endpoint, API key, and optionally
the inbound-registration endpoint. One scan replaces all the manual typing.

By default the link embeds ``ENGINE_API_KEY`` so one scan fully configures the
agent — which makes the link (and the QR) **as secret as the key itself**.
Pass ``--no-key`` to leave the key out and type it in the app instead.

Usage:
  uv run python scripts/pair.py --agent live --base-url https://<host>
  uv run python scripts/pair.py --agent live --transport livekit --inbound
  uv run python scripts/pair.py --agent loopback --no-key

No network calls — the link is built locally from .env-backed settings.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from urllib.parse import quote, urlencode

# Make the project root importable so we reuse the same .env-backed settings.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app.agents import AGENTS, resolve_transport  # noqa: E402
from app.config import settings  # noqa: E402


def build_link(
    base_url: str,
    agent_id: str,
    transport: str,
    name: str,
    key: str | None,
    inbound: bool,
) -> str:
    """The conduit://add-agent URL the app's DeepLinkParser accepts (v=1)."""
    base = base_url.rstrip("/")
    params: list[tuple[str, str]] = [
        ("v", "1"),
        ("name", name),
        ("transport", transport),
        ("pair", f"{base}/connect/{agent_id}"),
    ]
    if key:
        params.append(("key", key))
    if inbound:
        # The app POSTs the stored URL verbatim, so the full per-agent path
        # rides the link.
        params.append(("inbound", f"{base}/inbound/register/{agent_id}"))
    return "conduit://add-agent?" + urlencode(params, quote_via=quote)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Print a conduit:// pairing link + QR for the Conduit app."
    )
    parser.add_argument("--agent", default="loopback", help="Agent id (default: loopback).")
    parser.add_argument(
        "--transport",
        choices=["daily", "livekit", "smallwebrtc"],
        help="Default: the agent's own default.",
    )
    parser.add_argument("--name", help="Display name in the app (default: the agent id, title-cased).")
    parser.add_argument(
        "--base-url",
        default=settings.public_base_url or "http://localhost:8000",
        help="Engine base URL (default: PUBLIC_BASE_URL or http://localhost:8000).",
    )
    parser.add_argument(
        "--no-key", action="store_true", help="Leave ENGINE_API_KEY out of the link."
    )
    parser.add_argument(
        "--inbound", action="store_true",
        help="Include the inbound-registration endpoint (enables \"Let this agent call me\").",
    )
    parser.add_argument("--json", action="store_true", help="Print {link} as JSON instead.")
    args = parser.parse_args()

    agent = AGENTS.get(args.agent)
    if agent is None:
        print(f"Unknown agent {args.agent!r} — have: {', '.join(sorted(AGENTS))}", file=sys.stderr)
        sys.exit(1)

    key: str | None = None
    if not args.no_key:
        settings.require("engine_api_key")
        key = settings.engine_api_key

    link = build_link(
        base_url=args.base_url,
        agent_id=args.agent,
        transport=resolve_transport(agent, args.transport),
        name=args.name or args.agent.title(),
        key=key,
        inbound=args.inbound,
    )

    if args.json:
        print(json.dumps({"link": link}))
        return

    print(f"\nPairing link for agent '{args.agent}':\n")
    print(f"  {link}\n")
    try:
        import segno

        segno.make(link).terminal(compact=True)
        print()
    except ImportError:
        print("(Install deps with `uv sync` to also get a terminal QR code.)\n")
    if key:
        print("⚠️  This link contains your engine API key — treat it like the key itself.")
    else:
        print("The link carries no key — enter the API key in the app after scanning.")
    print("Scan with the iPhone Camera app, or open the link on the device.")


if __name__ == "__main__":
    main()
