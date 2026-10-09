"""The router's HTTP side: Home Assistant's agent calls it as its LLM.

A request is one round of the agent's tool loop: the context block, the
conversation so far, and, after a tool call, the tool's results. The first
round of a turn is routed (gate, local triage, cloud); a later round answers
a local act from its result, and goes back to the cloud otherwise.
"""
from __future__ import annotations

import asyncio
import datetime
import glob
import json
import logging
import os
import time
from dataclasses import dataclass

import aiohttp
from aiohttp import web

from . import actions, gate as gate_mod, honesty, triage
from .context import Context, parse_context
from .state import State

LOG = logging.getLogger("assistant-router")

# No question mark: Home Assistant keeps the microphone open after a reply
# that asks one, and a rejection heard back would loop.
SORRY = "Sorry, I didn't catch that."
STOPPED = "Okay."
CLARIFY = "Which one do you mean?"
CLOUD_DOWN = "I can't reach the online assistant right now."
OFFLINE = "I can't do that offline. I can control devices and media."
REFUSED = "I can't do that."

# What a cloud model may ask Home Assistant to run: the agent's two functions,
# with the actions their specs list (setup-ha.sh).
TOOL_ACTIONS = {
    "control_device": set(actions.SERVICE.values()),
    "media_control": set(actions.MEDIA_SERVICE.values()),
}


@dataclass
class Config:
    local_url: str
    local_model: str
    cloud_url: str
    cloud_model: str
    mode: str  # local-first | cloud-first | local-only
    local_timeout: float = 4.0
    cloud_timeout: float = 20.0
    log_dir: str | None = None
    log_days: int = 14
    log_text: bool = True


def _reply(text: str) -> dict:
    return {"model": "assistant", "object": "chat.completion",
            "choices": [{"index": 0, "finish_reason": "stop", "message": {"role": "assistant", "content": text}}]}


def _tool_reply(calls: list[dict]) -> dict:
    return {"model": "assistant", "object": "chat.completion",
            "choices": [{"index": 0, "finish_reason": "tool_calls",
                         "message": {"role": "assistant", "content": None, "tool_calls": calls}}]}


def _turn(messages: list[dict]) -> tuple[str, str, list[dict]]:
    """The last user text, the request it answers when the assistant had
    asked which device was meant, and the messages after it (this turn's
    rounds)."""
    for i in range(len(messages) - 1, -1, -1):
        if messages[i].get("role") == "user":
            text = messages[i].get("content") or ""
            asked = text
            if i >= 2 and messages[i - 1].get("role") == "assistant" \
                    and messages[i - 1].get("content") == CLARIFY and messages[i - 2].get("role") == "user":
                asked = f"{messages[i - 2].get('content') or ''} ({text})"
            return text, asked, messages[i + 1:]
    return "", "", []


def _allowed(calls: list[dict], ctx: Context | None) -> bool:
    """Every call is one of the agent's functions, on an exposed entity, with
    an action its spec lists."""
    ids = {e.entity_id for e in ctx.entities} if ctx else set()
    for call in calls:
        fn = call.get("function") or {}
        try:
            args = json.loads(fn.get("arguments") or "")
        except (TypeError, ValueError):
            return False
        if not isinstance(args, dict) or fn.get("name") not in TOOL_ACTIONS:
            return False
        if args.get("entity_id") not in ids or args.get("action") not in TOOL_ACTIONS[fn["name"]]:
            return False
    return True


def make_app(cfg: Config, state: State | None = None, clock=time.monotonic) -> web.Application:
    state = state or State()
    log_day = {"v": ""}

    def log(entry: dict) -> None:
        if not cfg.log_text:
            entry.pop("text", None)
        LOG.info(json.dumps(entry))
        if not cfg.log_dir:
            return
        today = datetime.date.today()
        if log_day["v"] != today.isoformat():
            log_day["v"] = today.isoformat()
            oldest = (today - datetime.timedelta(days=cfg.log_days)).isoformat()
            for path in glob.glob(os.path.join(cfg.log_dir, "requests-*.jsonl")):
                if os.path.basename(path)[len("requests-"):-len(".jsonl")] < oldest:
                    os.remove(path)
        with open(os.path.join(cfg.log_dir, f"requests-{today.isoformat()}.jsonl"), "a", encoding="utf-8") as f:
            f.write(json.dumps(entry) + "\n")

    async def cloud(session: aiohttp.ClientSession, body: dict) -> dict | None:
        # Home Assistant always sends temperature and top_p; current Claude
        # models refuse both together, so the provider's defaults apply.
        out = {k: v for k, v in body.items() if k not in ("temperature", "top_p", "user")}
        out["model"] = cfg.cloud_model
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

    def from_cloud(device: str, ctx: Context | None, data: dict | None, tool_results: list[str]) -> dict:
        if data is None:
            return finish(device, CLOUD_DOWN, tool_results)
        msg = data["choices"][0]["message"]
        calls = msg.get("tool_calls")
        if calls:
            return _tool_reply(calls) if _allowed(calls, ctx) else finish(device, REFUSED, tool_results)
        return finish(device, msg.get("content") or "", tool_results)

    async def completions(request: web.Request) -> web.Response:
        body = await request.json()
        messages = body.get("messages") or []
        conv = body.get("user") or ""
        system = messages[0].get("content") or "" if messages and messages[0].get("role") == "system" else ""
        ctx = parse_context(system)
        device = ctx.device_id if ctx else ""
        text, asked, rounds = _turn(messages)
        tool_results = [m.get("content") or "" for m in rounds if m.get("role") in ("tool", "function")]
        now = clock()
        session: aiohttp.ClientSession = request.app["session"]
        started = time.monotonic()

        # A later round of this turn: a local act's result, or the cloud's.
        if rounds:
            call_ids = [m.get("tool_call_id") or "" for m in rounds if m.get("role") == "tool"]
            t = state.take_pending(call_ids, now)
            if t is not None:
                said = actions.done_phrase(t) if "Success" in tool_results else "That didn't work."
                log({"conv": conv, "tier": "local", "round": "result", "results": tool_results})
                return web.json_response(finish(device, said, tool_results))
            return web.json_response(from_cloud(device, ctx, await cloud(session, body), tool_results))

        verdict = gate_mod.gate(text, state.last_reply(device, now)) if ctx else "escalate"
        tier, route = "gate", verdict
        if verdict == "reject":
            resp = finish(device, SORRY, [])
        elif verdict == "stop":
            resp = finish(device, STOPPED, [])
        else:
            t = triage.Triage("escalate")
            if verdict == "pass" and cfg.mode != "cloud-first":
                t = await triage.classify(session, cfg.local_url, cfg.local_model, ctx, asked, cfg.local_timeout)
                tier, route = "local", t.route
            if t.route == "act":
                calls = actions.tool_calls(t)
                state.add_pending(calls[0]["id"], t, now)
                resp = _tool_reply(calls)
            elif t.route == "reject":
                resp = finish(device, SORRY, [])
            elif t.route == "clarify":
                resp = finish(device, CLARIFY, [])
            elif cfg.mode == "local-only":
                resp = finish(device, OFFLINE, [])
            else:
                tier, route = "cloud", "escalate"
                resp = from_cloud(device, ctx, await cloud(session, body), [])
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
