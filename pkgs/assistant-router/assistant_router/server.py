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

from . import actions, body as body_mod, gate as gate_mod, honesty, triage
from .body import Bodies
from .context import Context, parse_context
from .people import People
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


def make_app(cfg: Config, state: State | None = None, clock=time.monotonic,
             bodies: Bodies | None = None, people: People | None = None) -> web.Application:
    state = state or State()
    bodies = bodies or Bodies("")
    people = people or People({})
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

    async def cloud(session: aiohttp.ClientSession, body: dict, room: str = "") -> dict | None:
        # Home Assistant always sends temperature and top_p; current Claude
        # models refuse both together, so the provider's defaults apply.
        out = {k: v for k, v in body.items() if k not in ("temperature", "top_p", "user")}
        out["model"] = cfg.cloud_model
        # A body in the room: its persona and what it senses go after Home
        # Assistant's block, so the start of the prompt stays the same.
        now = clock()
        block = "\n".join(b for b in (bodies.prompt_block(room, now), people.line(room, now)) if b)
        msgs = out.get("messages") or []
        if block and msgs and msgs[0].get("role") == "system":
            out["messages"] = [dict(msgs[0], content=(msgs[0].get("content") or "") + "\n" + block)] + msgs[1:]
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

    async def from_cloud(device: str, ctx: Context | None, data: dict | None, tool_results: list[str]) -> dict:
        if data is None:
            return finish(device, CLOUD_DOWN, tool_results)
        msg = data["choices"][0]["message"]
        calls = msg.get("tool_calls")
        if calls:
            return _tool_reply(calls) if _allowed(calls, ctx) else finish(device, REFUSED, tool_results)
        text = msg.get("content") or ""
        room = ctx.room if ctx else ""
        if bodies.has(room):
            mood, gesture, text = body_mod.split_tag(text)
            act = {k: v for k, v in (("mood", mood), ("gesture", gesture)) if v}
            await bodies.act(room, act)
        return finish(device, text, tool_results)

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
                ok = "Success" in tool_results
                said = actions.done_phrase(t) if ok else "That didn't work."
                if ok and ctx:
                    await bodies.act(ctx.room, {"mood": "happy", "gesture": "nod"})
                log({"conv": conv, "tier": "local", "round": "result", "results": tool_results})
                return web.json_response(finish(device, said, tool_results))
            return web.json_response(await from_cloud(
                device, ctx, await cloud(session, body, ctx.room if ctx else ""), tool_results))

        # A command to the room's body ("nod", "dance", "go to sleep") is
        # answered here, before the gate: "Nod." alone is a fragment to it.
        room = ctx.room if ctx else ""
        cmd = body_mod.command(text) if bodies.has(room) else None
        if cmd is not None:
            await bodies.act(room, cmd[0])
            log({"conv": conv, "device": device, "room": room, "text": text, "tier": "body", "route": "command",
                 "ms": int((time.monotonic() - started) * 1000)})
            return web.json_response(finish(device, cmd[1], []))

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
                resp = await from_cloud(device, ctx, await cloud(session, body, room), [])
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


def make_body_app(bodies: Bodies, clock=time.monotonic, people: People | None = None) -> web.Application:
    """The bodies' side (assistant_router/body.py): one WebSocket each, on its
    own listener, so the LAN reaches this and not the agent's endpoint.

    A robot ("kind": anything but "room-sensor") is the room's body; it may
    report the faces it recognises. A room sensor (pkgs/room-presence) is not
    a body: it only reports the phones it sees, and gets nothing back."""
    people = people or People({})

    async def socket(request: web.Request) -> web.WebSocketResponse:
        ws = web.WebSocketResponse(heartbeat=20)
        await ws.prepare(request)
        room, sensor = "", False
        try:
            async for msg in ws:
                if msg.type != aiohttp.WSMsgType.TEXT:
                    continue
                try:
                    data = json.loads(msg.data)
                except ValueError:
                    continue
                if not isinstance(data, dict):
                    continue
                hello = data.get("hello")
                if isinstance(hello, dict) and isinstance(hello.get("room"), str) and hello["room"].strip():
                    if room and not sensor:
                        bodies.disconnect(room, ws)
                    room = hello["room"].strip()[:64]
                    sensor = hello.get("kind") == "room-sensor"
                    if not sensor:
                        bodies.connect(room, ws)
                    LOG.info(json.dumps({"body": "connected", "room": room, "kind": str(hello.get("kind", ""))[:32]}))
                elif room and not sensor and isinstance(data.get("state"), dict):
                    bodies.update(room, data["state"], clock())
                    faces = data["state"].get("faces")
                    if isinstance(faces, list):
                        people.forget_faces(room)
                        for face in faces[:8]:
                            if isinstance(face, dict):
                                people.observe(room, "face", face.get("person"), face.get("confidence"), clock())
                elif room and sensor and isinstance(data.get("seen"), list):
                    for seen in data["seen"][:32]:
                        if isinstance(seen, dict) and type(seen.get("rssi")) is int and seen["rssi"] >= -85:
                            people.observe(room, "phone", seen.get("person"), 1.0, clock())
        finally:
            if room and not sensor:
                bodies.disconnect(room, ws)
                LOG.info(json.dumps({"body": "gone", "room": room}))
        return ws

    app = web.Application()
    app.router.add_get("/v1/body", socket)
    return app
