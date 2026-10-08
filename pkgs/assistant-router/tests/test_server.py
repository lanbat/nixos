import pytest
from aiohttp import web
from assistant_router.server import Config, make_app
from assistant_router.state import State

CTX = """LANBAT-CONTEXT v1
room: Bedroom 1
device: dev1
time: t
entities:
switch.office_light|Office light|Office|
media_player.kodi_binturong|Bedroom 1 TV|Bedroom 1|
end
"""


def req(text, extra=None, conv="c1"):
    msgs = [{"role": "system", "content": CTX}, {"role": "user", "content": text}] + (extra or [])
    return {"model": "assistant", "messages": msgs, "user": conv, "tools": []}


@pytest.fixture
async def fakes(aiohttp_server):
    seen = {"local": [], "cloud": []}
    local_line = {"v": "act 1 off"}
    cloud_reply = {"v": {"role": "assistant", "content": "It's the capital of the sea."}, "fail": False}

    async def local(request):
        seen["local"].append(await request.json())
        return web.json_response({"choices": [{"message": {"content": local_line["v"]}}]})

    async def cloud(request):
        body = await request.json()
        seen["cloud"].append(body)
        if cloud_reply["fail"]:
            return web.json_response({"error": "down"}, status=503)
        return web.json_response({"choices": [{"index": 0, "finish_reason": "stop", "message": cloud_reply["v"]}]})

    app = web.Application()
    app.router.add_post("/local/v1/chat/completions", local)
    app.router.add_post("/cloud/v1/chat/completions", cloud)
    srv = await aiohttp_server(app)
    base = f"http://{srv.host}:{srv.port}"
    return seen, local_line, cloud_reply, base


async def client_for(aiohttp_client, base, mode="local-first"):
    cfg = Config(local_url=f"{base}/local/v1/chat/completions", local_model="qwen3-4b",
                 cloud_url=f"{base}/cloud/v1/chat/completions", cloud_model="smart", mode=mode)
    return await aiohttp_client(make_app(cfg, State()))


async def post(client, body):
    r = await client.post("/v1/chat/completions", json=body)
    assert r.status == 200
    return (await r.json())["choices"][0]


async def test_local_act_returns_tool_call_then_short_reply(aiohttp_client, fakes):
    seen, local_line, _, base = fakes
    c = await client_for(aiohttp_client, base)
    choice = await post(c, req("Turn off the office light."))
    assert choice["finish_reason"] == "tool_calls"
    call = choice["message"]["tool_calls"][0]
    assert call["function"]["name"] == "control_device"
    tool_round = [choice["message"], {"role": "tool", "tool_call_id": call["id"], "name": "control_device", "content": "Success"}]
    final = await post(c, req("Turn off the office light.", tool_round))
    assert final["message"]["content"] == "Office light off."
    assert seen["cloud"] == []


async def test_gate_reject_never_reaches_a_model(aiohttp_client, fakes):
    seen, _, _, base = fakes
    c = await client_for(aiohttp_client, base)
    assert (await post(c, req("Turn on, bye.")))["message"]["content"] == "Sorry?"
    assert seen["local"] == [] and seen["cloud"] == []


async def test_echo_of_last_reply_rejected(aiohttp_client, fakes):
    seen, _, cloud_reply, base = fakes
    cloud_reply["v"] = {"role": "assistant", "content": "I can't play and stop the radio. Let me know if you need anything else."}
    c = await client_for(aiohttp_client, base)
    await post(c, req("Tell me about radios", conv="a"))
    choice = await post(c, req("I can't play and stop the radios. Let me know if you need anything else.", conv="b"))
    assert choice["message"]["content"] == "Sorry?"


async def test_escalation_proxies_cloud_and_marks_tier(aiohttp_client, fakes):
    seen, local_line, _, base = fakes
    local_line["v"] = "escalate"
    c = await client_for(aiohttp_client, base)
    choice = await post(c, req("Is octopus blood blue"))
    assert choice["message"]["content"] == "It's the capital of the sea."
    assert seen["cloud"][-1]["model"] == "smart"


async def test_tool_round_stays_on_cloud(aiohttp_client, fakes):
    seen, local_line, cloud_reply, base = fakes
    cloud_reply["v"] = {"role": "assistant", "content": None, "tool_calls": [
        {"id": "x", "type": "function", "function": {"name": "control_device", "arguments": "{}"}}]}
    c = await client_for(aiohttp_client, base)
    first = await post(c, req("Tell me a joke and turn the light off"))
    assert first["finish_reason"] == "tool_calls"
    cloud_reply["v"] = {"role": "assistant", "content": "Turned the office light off."}
    n_local = len(seen["local"])
    final = await post(c, req("Tell me a joke and turn the light off",
                              [first["message"], {"role": "tool", "tool_call_id": "x", "name": "control_device", "content": "Success"}]))
    assert final["message"]["content"] == "Turned the office light off."
    assert len(seen["local"]) == n_local


async def test_escalation_failure_is_honest(aiohttp_client, fakes):
    seen, local_line, cloud_reply, base = fakes
    local_line["v"] = "escalate"
    cloud_reply["fail"] = True
    c = await client_for(aiohttp_client, base)
    assert (await post(c, req("Tell me a joke")))["message"]["content"] == "I can't reach the online assistant right now."


async def test_unbacked_cloud_claim_is_replaced(aiohttp_client, fakes):
    seen, local_line, cloud_reply, base = fakes
    local_line["v"] = "escalate"
    cloud_reply["v"] = {"role": "assistant", "content": "Okay, it's on."}
    c = await client_for(aiohttp_client, base)
    assert (await post(c, req("Make it cosy")))["message"]["content"] == "I didn't change anything."


async def test_local_only_mode_never_calls_cloud(aiohttp_client, fakes):
    seen, local_line, _, base = fakes
    local_line["v"] = "escalate"
    c = await client_for(aiohttp_client, base, mode="local-only")
    choice = await post(c, req("Tell me a joke"))
    assert choice["message"]["content"].startswith("I can't do that offline.")
    assert seen["cloud"] == []


async def test_cloud_first_skips_local(aiohttp_client, fakes):
    seen, _, _, base = fakes
    c = await client_for(aiohttp_client, base, mode="cloud-first")
    await post(c, req("Turn off the office light."))
    assert seen["local"] == [] and len(seen["cloud"]) == 1


async def test_stop_is_acknowledged_without_models(aiohttp_client, fakes):
    seen, _, _, base = fakes
    c = await client_for(aiohttp_client, base)
    assert (await post(c, req("Stop.")))["message"]["content"] == "Okay."
    assert seen["local"] == []


async def test_without_context_block_everything_goes_to_cloud(aiohttp_client, fakes):
    seen, _, _, base = fakes
    c = await client_for(aiohttp_client, base)
    body = {"model": "assistant", "messages": [{"role": "user", "content": "hello there friend"}], "user": "z"}
    await post(c, body)
    assert len(seen["cloud"]) == 1
