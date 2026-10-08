"""The router's HTTP side: Home Assistant's agent calls it as its LLM.

A request is one round of the agent's tool loop: the context block, the
conversation so far, and, after a tool call, the tool's results. The first
round of a turn is routed (gate, local triage, cloud); later rounds of the
same turn stay on the tier that asked for the tools.
"""
from __future__ import annotations

import asyncio
import json
import logging
import time
from dataclasses import dataclass

import aiohttp
from aiohttp import web

from . import actions, gate as gate_mod, honesty, triage
from .context import parse_context
from .state import State

LOG = logging.getLogger("assistant-router")

SORRY = "Sorry?"
STOPPED = "Okay."
CLARIFY = "Which one do you mean?"
CLOUD_DOWN = "I can't reach the online assistant right now."
OFFLINE = "I can't do that offline. I can control devices, media and timers."


@dataclass
class Config:
    local_url: str
    local_model: str
    cloud_url: str
    cloud_model: str
    mode: str  # local-first | cloud-first | local-only
    local_timeout: float = 4.0
    cloud_timeout: float = 20.0
    log_path: str | None = None


def _reply(text: str) -> dict:
    return {"model": "assistant", "object": "chat.completion",
            "choices": [{"index": 0, "finish_reason": "stop", "message": {"role": "assistant", "content": text}}]}


def _tool_reply(calls: list[dict]) -> dict:
    return {"model": "assistant", "object": "chat.completion",
            "choices": [{"index": 0, "finish_reason": "tool_calls",
                         "message": {"role": "assistant", "content": None, "tool_calls": calls}}]}


def _turn(messages: list[dict]) -> tuple[str, list[dict]]:
    """The last user text and the messages after it (this turn's rounds)."""
    for i in range(len(messages) - 1, -1, -1):
        if messages[i].get("role") == "user":
            return messages[i].get("content") or "", messages[i + 1:]
    return "", []


def make_app(cfg: Config, state: State | None = None, clock=time.monotonic) -> web.Application:
    state = state or State()
    pending: dict[str, triage.Triage] = {}  # conversation -> local act awaiting its tool result

    def log(entry: dict) -> None:
        LOG.info(json.dumps(entry))
        if cfg.log_path:
            with open(cfg.log_path, "a", encoding="utf-8") as f:
                f.write(json.dumps(entry) + "\n")

    async def cloud(session: aiohttp.ClientSession, body: dict) -> dict | None:
        out = dict(body, model=cfg.cloud_model)
        try:
            async with session.post(cfg.cloud_url, json=out,
                                    timeout=aiohttp.ClientTimeout(total=cfg.cloud_timeout)) as r:
                if r.status != 200:
                    return None
                return await r.json()
        except (aiohttp.ClientError, asyncio.TimeoutError):
            return None

    def finish(device: str, text: str, tool_results: list[str]) -> dict:
        said = honesty.check(honesty.speakable(text), tool_results)
        state.remember_reply(device, said, clock())
        return _reply(said)

    async def completions(request: web.Request) -> web.Response:
        body = await request.json()
        messages = body.get("messages") or []
        conv = body.get("user") or ""
        system = messages[0].get("content") or "" if messages and messages[0].get("role") == "system" else ""
        ctx = parse_context(system)
        device = ctx.device_id if ctx else ""
        text, rounds = _turn(messages)
        tool_results = [m.get("content") or "" for m in rounds if m.get("role") in ("tool", "function")]
        now = clock()
        session: aiohttp.ClientSession = request.app["session"]
        started = time.monotonic()

        # A later round of this turn: answer from the tier that called the tools.
        if rounds:
            if conv in pending:
                t = pending.pop(conv)
                said = actions.done_phrase(t) if "Success" in tool_results else "That didn't work."
                log({"conv": conv, "tier": "local", "round": "result", "results": tool_results})
                return web.json_response(finish(device, said, tool_results))
            data = await cloud(session, body)
            if data is None:
                return web.json_response(finish(device, CLOUD_DOWN, tool_results))
            msg = data["choices"][0]["message"]
            if msg.get("tool_calls"):
                return web.json_response(_tool_reply(msg["tool_calls"]))
            return web.json_response(finish(device, msg.get("content") or "", tool_results))

        verdict = gate_mod.gate(text, state.last_reply(device, now)) if ctx else "escalate"
        tier, route = "gate", verdict
        if verdict == "reject":
            resp = finish(device, SORRY, [])
        elif verdict == "stop":
            resp = finish(device, STOPPED, [])
        else:
            t = triage.Triage("escalate")
            if verdict == "pass" and cfg.mode != "cloud-first":
                t = await triage.classify(session, cfg.local_url, cfg.local_model, ctx, text, cfg.local_timeout)
                tier, route = "local", t.route
            if t.route == "act":
                pending[conv] = t
                resp = _tool_reply(actions.tool_calls(t))
            elif t.route == "reject":
                resp = finish(device, SORRY, [])
            elif t.route == "clarify":
                resp = finish(device, CLARIFY, [])
            elif cfg.mode == "local-only":
                resp = finish(device, OFFLINE, [])
            else:
                tier, route = "cloud", "escalate"
                state.set_tier(conv, "cloud", now)
                data = await cloud(session, body)
                if data is None:
                    resp = finish(device, CLOUD_DOWN, [])
                else:
                    msg = data["choices"][0]["message"]
                    resp = _tool_reply(msg["tool_calls"]) if msg.get("tool_calls") else \
                        finish(device, msg.get("content") or "", [])
        log({"conv": conv, "device": device, "room": ctx.room if ctx else "", "text": text,
             "tier": tier, "route": route, "ms": int((time.monotonic() - started) * 1000)})
        return web.json_response(resp)

    async def healthz(_request: web.Request) -> web.Response:
        return web.Response(text="ok")

    async def on_startup(app: web.Application) -> None:
        app["session"] = aiohttp.ClientSession()

    async def on_cleanup(app: web.Application) -> None:
        await app["session"].close()

    app = web.Application()
    app.router.add_post("/v1/chat/completions", completions)
    app.router.add_get("/healthz", healthz)
    app.on_startup.append(on_startup)
    app.on_cleanup.append(on_cleanup)
    return app
