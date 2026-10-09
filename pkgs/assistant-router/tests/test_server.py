import json
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
media_player.kodi_tv|Bedroom 1 TV|Bedroom 1|
end
"""


def req(text, extra=None, conv="c1", history=None):
    msgs = [{"role": "system", "content": CTX}] + (history or []) + [{"role": "user", "content": text}] + (extra or [])
    return {"model": "assistant", "messages": msgs, "user": conv, "tools": [], "temperature": 0.5, "top_p": 1.0}


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
    assert (await post(c, req("Turn on, bye.")))["message"]["content"] == "Sorry, I didn't catch that."
    assert seen["local"] == [] and seen["cloud"] == []


async def test_echo_of_last_reply_rejected(aiohttp_client, fakes):
    seen, _, cloud_reply, base = fakes
    cloud_reply["v"] = {"role": "assistant", "content": "I can't play and stop the radio. Let me know if you need anything else."}
    c = await client_for(aiohttp_client, base)
    await post(c, req("Tell me about radios", conv="a"))
    choice = await post(c, req("I can't play and stop the radios. Let me know if you need anything else.", conv="b"))
    assert choice["message"]["content"] == "Sorry, I didn't catch that."


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
        {"id": "x", "type": "function", "function": {"name": "control_device",
                                                      "arguments": '{"entity_id": "switch.office_light", "action": "turn_off"}'}}]}
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


async def test_rejections_do_not_ask_a_question(aiohttp_client, fakes):
    # A question keeps the microphone open (Home Assistant's continue_conversation).
    seen, _, _, base = fakes
    c = await client_for(aiohttp_client, base)
    assert not (await post(c, req("Done.")))["message"]["content"].endswith("?")


async def test_knowledge_answer_with_action_words_reaches_the_user(aiohttp_client, fakes):
    seen, local_line, cloud_reply, base = fakes
    local_line["v"] = "escalate"
    cloud_reply["v"] = {"role": "assistant", "content": "World War Two started in 1939."}
    c = await client_for(aiohttp_client, base)
    assert (await post(c, req("When did the war start")))["message"]["content"] == "World War Two started in 1939."


async def test_cloud_gets_no_sampling_parameters(aiohttp_client, fakes):
    seen, local_line, _, base = fakes
    local_line["v"] = "escalate"
    c = await client_for(aiohttp_client, base)
    await post(c, req("Tell me a joke"))
    sent = seen["cloud"][-1]
    assert "top_p" not in sent and "temperature" not in sent and "user" not in sent


@pytest.mark.parametrize("call", [
    {"name": "control_device", "arguments": '{"entity_id": "cover.garage", "action": "open"}'},
    {"name": "control_device", "arguments": '{"entity_id": "switch.office_light", "action": "restart"}'},
    {"name": "shell", "arguments": "{}"},
    {"name": "media_control", "arguments": "not json"},
])
async def test_cloud_tool_calls_outside_the_house_are_refused(aiohttp_client, fakes, call):
    seen, local_line, cloud_reply, base = fakes
    local_line["v"] = "escalate"
    cloud_reply["v"] = {"role": "assistant", "content": None,
                        "tool_calls": [{"id": "x", "type": "function", "function": call}]}
    c = await client_for(aiohttp_client, base)
    choice = await post(c, req("Make it cosy"))
    assert choice["finish_reason"] == "stop"
    assert choice["message"]["content"] == "I can't do that."


async def test_a_valid_cloud_tool_call_passes(aiohttp_client, fakes):
    seen, local_line, cloud_reply, base = fakes
    local_line["v"] = "escalate"
    cloud_reply["v"] = {"role": "assistant", "content": None, "tool_calls": [{"id": "x", "type": "function",
        "function": {"name": "media_control", "arguments": '{"entity_id": "media_player.kodi_tv", "action": "volume_set", "value": 20}'}}]}
    c = await client_for(aiohttp_client, base)
    assert (await post(c, req("Make it quieter in here")))["finish_reason"] == "tool_calls"


async def test_answer_to_clarify_is_read_with_the_request(aiohttp_client, fakes):
    seen, local_line, _, base = fakes
    c = await client_for(aiohttp_client, base)
    history = [{"role": "user", "content": "Turn off the light"},
               {"role": "assistant", "content": "Which one do you mean?"}]
    await post(c, req("the office one", history=history))
    asked = seen["local"][-1]["messages"][-1]["content"]
    assert "Turn off the light" in asked and "the office one" in asked


async def test_stale_local_act_does_not_answer_a_cloud_round(aiohttp_client, fakes):
    seen, local_line, cloud_reply, base = fakes
    c = await client_for(aiohttp_client, base)
    first = await post(c, req("Turn off the office light."))  # local act; HA's tool then fails, no result round
    assert first["finish_reason"] == "tool_calls"
    cloud_reply["v"] = {"role": "assistant", "content": "Here is your joke."}
    later = await post(c, req("Tell me a joke", [
        {"role": "assistant", "content": None, "tool_calls": [{"id": "cloud1", "type": "function",
                                                                 "function": {"name": "control_device", "arguments": "{}"}}]},
        {"role": "tool", "tool_call_id": "cloud1", "name": "control_device", "content": "Success"}]))
    assert later["message"]["content"] == "Here is your joke."


async def test_request_log_rotates_daily_and_keeps_n_days(aiohttp_client, fakes, tmp_path):
    import datetime
    from assistant_router.server import Config, make_app
    from assistant_router.state import State
    seen, _, _, base = fakes
    old = tmp_path / "requests-2020-01-01.jsonl"
    old.write_text("{}\n")
    cfg = Config(local_url=f"{base}/local/v1/chat/completions", local_model="m",
                 cloud_url=f"{base}/cloud/v1/chat/completions", cloud_model="smart", mode="local-first",
                 log_dir=str(tmp_path), log_days=14, log_text=False)
    c = await aiohttp_client(make_app(cfg, State()))
    await post(c, req("Done."))
    today = tmp_path / f"requests-{datetime.date.today().isoformat()}.jsonl"
    assert today.exists() and not old.exists()
    entry = json.loads(today.read_text().splitlines()[-1])
    assert "text" not in entry and entry["route"] == "reject"


def test_cli_takes_the_local_time_limit():
    from assistant_router import __main__ as cli
    cfg, _ = cli.config(["--local-url", "l", "--local-model", "m", "--cloud-url", "c", "--local-timeout", "2.5"])
    assert cfg.local_timeout == 2.5


def test_cli_takes_the_body_listener():
    from assistant_router import __main__ as cli
    _, a = cli.config(["--local-url", "l", "--local-model", "m", "--cloud-url", "c",
                       "--body-host", "0.0.0.0", "--body-port", "8770", "--persona-file", "p.txt"])
    assert (a.body_host, a.body_port, a.persona_file) == ("0.0.0.0", 8770, "p.txt")
    _, a = cli.config(["--local-url", "l", "--local-model", "m", "--cloud-url", "c"])
    assert a.body_port == 0  # no bodies unless asked


async def test_a_local_act_the_words_dont_back_goes_to_the_cloud(aiohttp_client, fakes):
    seen, local_line, _, base = fakes
    local_line["v"] = "act 0 on"  # the model's answer to "Pause." on the server
    c = await client_for(aiohttp_client, base)
    choice = await post(c, req("Pause."))
    assert choice["finish_reason"] == "stop" and len(seen["cloud"]) == 1


# ── a body in the room (assistant_router/body.py) ─────────────────────────────
from assistant_router.body import Bodies  # noqa: E402
from assistant_router.server import make_body_app  # noqa: E402


class Sock:
    def __init__(self):
        self.sent = []

    async def send_json(self, data):
        self.sent.append(data)


async def body_client(aiohttp_client, base, room="Bedroom 1"):
    cfg = Config(local_url=f"{base}/local/v1/chat/completions", local_model="qwen3-4b",
                 cloud_url=f"{base}/cloud/v1/chat/completions", cloud_model="smart", mode="local-first")
    bodies = Bodies("You are Nabu, a little robot.")
    sock = Sock()
    if room:
        bodies.connect(room, sock)
    return await aiohttp_client(make_app(cfg, State(), bodies=bodies)), bodies, sock


async def test_body_command_is_answered_here(aiohttp_client, fakes):
    seen, _, _, base = fakes
    c, _, sock = await body_client(aiohttp_client, base)
    choice = await post(c, req("Do a little dance!"))
    assert choice["message"]["content"] == "Here I go!"
    assert sock.sent == [{"act": {"mood": "excited", "gesture": "dance"}}]
    assert seen["local"] == [] and seen["cloud"] == []


async def test_body_command_without_a_body_takes_the_normal_path(aiohttp_client, fakes):
    seen, local_line, _, base = fakes
    local_line["v"] = "escalate"
    c, _, sock = await body_client(aiohttp_client, base, room="Kitchen")
    await post(c, req("Do a little dance!"))
    assert sock.sent == []
    assert len(seen["cloud"]) == 1


async def test_cloud_gets_the_persona_and_its_tag_drives_the_body(aiohttp_client, fakes):
    seen, local_line, cloud_reply, base = fakes
    local_line["v"] = "escalate"
    cloud_reply["v"] = {"role": "assistant", "content": "[excited nod] Good morning! What a lovely day."}
    c, _, sock = await body_client(aiohttp_client, base)
    choice = await post(c, req("Good morning"))
    assert choice["message"]["content"] == "Good morning! What a lovely day."
    assert sock.sent == [{"act": {"mood": "excited", "gesture": "nod"}}]
    system = seen["cloud"][-1]["messages"][0]["content"]
    assert system.startswith(CTX)  # Home Assistant's block untouched, the body's after it
    assert "You are Nabu" in system and "Nobody is in front of you" in system


async def test_without_a_body_the_cloud_request_is_unchanged(aiohttp_client, fakes):
    seen, local_line, cloud_reply, base = fakes
    local_line["v"] = "escalate"
    c, _, _ = await body_client(aiohttp_client, base, room="Kitchen")
    await post(c, req("Good morning"))
    assert seen["cloud"][-1]["messages"][0]["content"] == CTX


async def test_a_local_act_makes_the_body_nod(aiohttp_client, fakes):
    _, _, _, base = fakes
    c, _, sock = await body_client(aiohttp_client, base)
    choice = await post(c, req("Turn off the office light."))
    call = choice["message"]["tool_calls"][0]
    await post(c, req("Turn off the office light.", [choice["message"], {
        "role": "tool", "tool_call_id": call["id"], "name": "control_device", "content": "Success"}]))
    assert sock.sent == [{"act": {"mood": "happy", "gesture": "nod"}}]


async def test_a_body_connects_and_reports_over_its_socket(aiohttp_client):
    bodies = Bodies("You are Nabu.")
    c = await aiohttp_client(make_body_app(bodies, clock=lambda: 1000.0))
    ws = await c.ws_connect("/v1/body")
    await ws.send_json({"hello": {"room": "Kitchen", "kind": "stackchan", "proto": 1}})
    await ws.send_json({"state": {"present": True, "present_since_s": 0, "asleep": False}})
    await ws.send_json({"ping": 1})  # anything else is ignored
    for _ in range(50):
        if bodies.has("Kitchen") and bodies.state("Kitchen").present:
            break
        import asyncio
        await asyncio.sleep(0.01)
    assert bodies.state("Kitchen").present
    assert await bodies.act("Kitchen", {"gesture": "nod"})
    assert (await ws.receive_json()) == {"act": {"gesture": "nod"}}
    await ws.close()


# ── who is there (assistant_router/people.py) ─────────────────────────────────
from assistant_router.people import People  # noqa: E402


async def test_the_cloud_hears_who_is_there(aiohttp_client, fakes):
    seen, local_line, _, base = fakes
    local_line["v"] = "escalate"
    cfg = Config(local_url=f"{base}/local/v1/chat/completions", local_model="qwen3-4b",
                 cloud_url=f"{base}/cloud/v1/chat/completions", cloud_model="smart", mode="local-first")
    people = People({"kiril": "Kiril"})
    people.observe("Bedroom 1", "phone", "kiril", 1.0, now=0.0)
    c = await aiohttp_client(make_app(cfg, State(), people=people, clock=lambda: 10.0))
    await post(c, req("Good morning"))
    system = seen["cloud"][-1]["messages"][0]["content"]
    assert system.startswith(CTX)
    assert "Kiril is nearby" in system


async def test_who_is_there_never_changes_a_device_action(aiohttp_client, fakes):
    seen, _, _, base = fakes
    cfg = Config(local_url=f"{base}/local/v1/chat/completions", local_model="qwen3-4b",
                 cloud_url=f"{base}/cloud/v1/chat/completions", cloud_model="smart", mode="local-first")
    people = People({"kiril": "Kiril"})
    people.observe("Bedroom 1", "phone", "kiril", 1.0, now=0.0)
    c = await aiohttp_client(make_app(cfg, State(), people=people, clock=lambda: 10.0))
    choice = await post(c, req("Turn off the office light."))
    call = choice["message"]["tool_calls"][0]
    assert json.loads(call["function"]["arguments"]) == {"entity_id": "switch.office_light", "action": "turn_off"}
    assert "Kiril" not in json.dumps(seen["local"])  # the local model never sees it


async def test_a_robot_reports_faces_and_a_sensor_reports_phones(aiohttp_client):
    import asyncio
    bodies, people = Bodies("You are Nabu."), People({"kiril": "Kiril", "maria": "Maria"})
    c = await aiohttp_client(make_body_app(bodies, clock=lambda: 100.0, people=people))
    robot = await c.ws_connect("/v1/body")
    await robot.send_json({"hello": {"room": "Kitchen", "kind": "stackchan", "proto": 1}})
    await robot.send_json({"state": {"present": True, "faces": [{"person": "kiril", "confidence": 0.9},
                                                                  {"person": "nobody", "confidence": 0.9}]}})
    sensor = await c.ws_connect("/v1/body")
    await sensor.send_json({"hello": {"room": "Kitchen", "kind": "room-sensor", "proto": 1}})
    await sensor.send_json({"seen": [{"person": "maria", "rssi": -70}, {"person": "maria", "rssi": "loud"}]})
    for _ in range(50):
        line = people.line("Kitchen", now=100.0)
        if line and "Maria" in line and "Kiril" in line:
            break
        await asyncio.sleep(0.01)
    assert "talking to Kiril" in line and "Maria is nearby" in line
    # A sensor is not a body: no persona, no acts for it.
    assert bodies.has("Kitchen")
    await sensor.close()
    assert bodies.has("Kitchen")
    await robot.close()
