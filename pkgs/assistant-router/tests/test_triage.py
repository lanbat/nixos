from assistant_router.context import Context, Entity
from assistant_router.triage import Triage, controllable, local_prompt, parse

ENTS = [Entity("switch.office_light", "Office light", "Office"),
        Entity("media_player.kodi_tv", "Bedroom 1 TV", "Bedroom 1"),
        Entity("todo.shopping_list", "Shopping List", "")]
CTX = Context("Bedroom 1", "dev", "t", tuple(ENTS))


def test_only_controllable_entities_are_numbered():
    ids = [e.entity_id for e in controllable(CTX)]
    assert ids == ["media_player.kodi_tv", "switch.office_light"]


def test_prompt_is_stable_and_lists_rooms():
    p = local_prompt(controllable(CTX))
    assert "0 Bedroom 1 TV (Bedroom 1)" in p and "1 Office light (Office)" in p
    assert p == local_prompt(controllable(CTX))


def test_parse_act():
    t = parse("act 1 off", controllable(CTX))
    assert t == Triage("act", controllable(CTX)[1], "off", None)


def test_parse_value():
    assert parse("act 0 volume_set 30", controllable(CTX)).value == 30


def test_out_of_range_device_clarifies():
    assert parse("act 9 off", controllable(CTX)).route == "clarify"


def test_action_must_fit_domain():
    # "pause" on a switch is not a thing: ask rather than guess.
    assert parse("act 1 pause", controllable(CTX)).route == "clarify"


def test_other_routes_and_garbage():
    assert parse("escalate", []).route == "escalate"
    assert parse("reject", []).route == "reject"
    assert parse("", []).route == "escalate"


import pytest
from assistant_router.triage import agrees

TV = Entity("media_player.kodi_tv", "Bedroom 1 TV", "Bedroom 1")
LIGHT = Entity("switch.office_light", "Office light", "Office")


@pytest.mark.parametrize("text,action", [
    ("Turn off the office light.", "off"), ("Switch the light on", "on"), ("Turn on bedroom or sunlight.", "on"),
    ("Pause the TV.", "pause"), ("Resume the film", "play"), ("Skip this one", "next"), ("Stop playing.", "stop"),
    ("Louder please", "volume_up"), ("Turn it down", "volume_down"), ("volume to 30%", "volume_set"),
    ("Open the blinds", "open"), ("Close the curtains", "close"),
])
def test_actions_backed_by_the_words_said(text, action):
    assert agrees(Triage("act", TV if action not in ("on", "off", "open", "close") else LIGHT, action), text)


@pytest.mark.parametrize("text,action", [
    ("Pause.", "on"), ("Pause the film.", "on"), ("Pause the TV.", "off"),
    ("Turn off the office light.", "on"), ("Turn on the light", "off"), ("Louder", "volume_down"),
])
def test_actions_the_words_dont_back_are_refused(text, action):
    assert not agrees(Triage("act", TV, action), text)
