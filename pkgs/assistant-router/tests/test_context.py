from assistant_router.context import parse_context

PROMPT = """LANBAT-CONTEXT v1
room: Bedroom 1
device: abc123
time: 2026-10-08T09:30:00+01:00
entities:
switch.office_light|Office light|Office|
media_player.kodi_tv|Bedroom 1 TV|Bedroom 1|telly/tv
end
"""


def test_parses_room_device_time_and_entities():
    ctx = parse_context(PROMPT)
    assert ctx.room == "Bedroom 1"
    assert ctx.device_id == "abc123"
    assert ctx.time.startswith("2026-10-08T09:30")
    assert [e.entity_id for e in ctx.entities] == ["switch.office_light", "media_player.kodi_tv"]
    assert ctx.entities[1].aliases == ("telly", "tv")
    assert ctx.entities[1].domain == "media_player"


def test_other_prompts_are_not_context():
    assert parse_context("You are a helpful assistant.") is None


def test_empty_room_and_pipes_in_names_survive():
    ctx = parse_context("LANBAT-CONTEXT v1\nroom: \ndevice: \ntime: x\nentities:\nlight.a|A|B|\nend\n")
    assert ctx.room == "" and ctx.device_id == ""
    assert ctx.entities[0].name == "A"
