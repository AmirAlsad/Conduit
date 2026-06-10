"""SmallWebRTC service: offer-token store + in-process bot lifecycle.

SmallWebRTC inverts the dispatch model. Daily/LiveKit pairing creates a cloud
room and dispatches a bot subprocess that joins it; here the client's SDP offer
POST *is* the rendezvous — the aiortc peer connection lives in this process, so
the bot runs as an asyncio task next to the dispatcher rather than a subprocess.
That makes this transport a LAN / self-hosted-with-UDP option: media is UDP, so
it cannot work behind an HTTP-only ingress like Railway's.

Pairing still flows through /connect/{agent_id}: it mints a short-lived offer
token here and returns the offer URL as ``connection.room_url``, so the app's
pairing contract is unchanged.

Pipecat imports are deferred to first use so the dispatcher process stays light
on deploys that never take a SmallWebRTC call.
"""

from __future__ import annotations

import asyncio
import hmac
import secrets
import time

from app.obs import event, get_logger


class SmallWebRTCService:
    def __init__(self) -> None:
        self._handler = None
        self._tokens: dict[str, tuple[str, float]] = {}  # token -> (agent_id, expires_at)
        self._tasks: set[asyncio.Task] = set()
        self._log = get_logger("smallwebrtc")

    # --- ephemeral offer tokens (the pairing "credential" for this transport) ---

    def mint_token(self, agent_id: str, ttl_secs: int) -> str:
        self._prune()
        token = secrets.token_hex(16)
        self._tokens[token] = (agent_id, time.time() + ttl_secs)
        return token

    def validate_token(self, presented: str, agent_id: str) -> bool:
        """Constant-time scan over the (small) live-token set; expiry gates only
        the initial offer — the in-flight ICE PATCHes reuse the same header well
        within the TTL."""
        self._prune()
        ok = False
        for token, (owner, _expires) in self._tokens.items():
            if hmac.compare_digest(presented, token) and owner == agent_id:
                ok = True
        return ok

    def _prune(self) -> None:
        now = time.time()
        self._tokens = {t: v for t, v in self._tokens.items() if v[1] > now}

    # --- offer/answer + in-process bots ---

    @property
    def handler(self):
        if self._handler is None:
            from pipecat.transports.smallwebrtc.request_handler import (
                SmallWebRTCRequestHandler,
            )

            self._handler = SmallWebRTCRequestHandler()
        return self._handler

    async def handle_offer(self, agent_id: str, payload: dict) -> dict:
        from pipecat.transports.smallwebrtc.request_handler import SmallWebRTCRequest

        request = SmallWebRTCRequest.from_dict(payload)

        async def _on_connection(connection) -> None:  # noqa: ANN001
            from bot.runtime import run_bot
            from bot.transport_factory import build_transport

            transport = build_transport("smallwebrtc", {"connection": connection})
            task = asyncio.create_task(
                run_bot(
                    transport,
                    agent_id,
                    "smallwebrtc",
                    # In-process under uvicorn: installing signal handlers here
                    # would clobber uvicorn's own SIGINT/SIGTERM handling.
                    handle_sigint=False,
                    handle_sigterm=False,
                )
            )
            self.track(task)
            event(self._log, "bot.dispatched_in_process", agent=agent_id, transport="smallwebrtc")

        answer = await self.handler.handle_web_request(request, _on_connection)
        return answer

    async def handle_patch(self, payload: dict) -> None:
        from pipecat.transports.smallwebrtc.request_handler import (
            IceCandidate,
            SmallWebRTCPatchRequest,
        )

        request = SmallWebRTCPatchRequest(
            pc_id=payload["pc_id"],
            candidates=[IceCandidate(**c) for c in payload["candidates"]],
        )
        await self.handler.handle_patch_request(request)

    def track(self, task: asyncio.Task) -> None:
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)

    async def close(self) -> None:
        for task in list(self._tasks):
            task.cancel()
        if self._tasks:
            await asyncio.gather(*self._tasks, return_exceptions=True)
        if self._handler is not None:
            await self._handler.close()
