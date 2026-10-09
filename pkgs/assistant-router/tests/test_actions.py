import json
from assistant_router.context import Entity
from assistant_router.actions import done_phrase, tool_calls
from assistant_router.triage import Triage

LIGHT = Entity("switch.office_light", "Office light", "Office")
TV = Entity("media_player.kodi_tv", "Bedroom 1 TV", "Bedroom 1")


def test_switch_off_is_control_device():
    (call,) = tool_calls(Triage("act", LIGHT, "off"))
    assert call["type"] == "function" and call["function"]["name"] == "control_device"
    assert json.loads(call["function"]["arguments"]) == {"entity_id": "switch.office_light", "action": "turn_off"}


def test_volume_set_is_media_control_with_value():
    (call,) = tool_calls(Triage("act", TV, "volume_set", 30))
    assert call["function"]["name"] == "media_control"
    assert json.loads(call["function"]["arguments"]) == {"entity_id": "media_player.kodi_tv",
                                                         "action": "volume_set", "value": 30}


def test_done_phrases_name_the_device():
    assert done_phrase(Triage("act", LIGHT, "off")) == "Office light off."
    assert done_phrase(Triage("act", TV, "pause")) == "Paused."
