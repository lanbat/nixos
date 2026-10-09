from assistant_router.honesty import check, speakable


def test_claim_without_tool_success_is_replaced():
    assert check("Okay, it's on.", []) == "I didn't change anything."
    assert check("Done. Turning off the hall.", ["Error"]) == "I didn't change anything."


def test_claim_with_success_stays():
    assert check("Turned off the hall light.", ["Success"]) == "Turned off the hall light."


def test_plain_answers_untouched():
    assert check("It's about twenty degrees.", []) == "It's about twenty degrees."


def test_speakable_strips_ids_markdown_and_done_tails():
    assert speakable("**Done.** Turning off the livingroom_newyork_spot. Done.") == \
        "Turning off the livingroom newyork spot."


import pytest


@pytest.mark.parametrize("text", ["World War Two started in 1939.", "The pharmacy is closed on Sundays.",
                                  "He turned forty last year.", "Your alarm is set to seven.", "The store opened in 1990."])
def test_knowledge_answers_are_not_claims(text):
    assert check(text, []) == text


@pytest.mark.parametrize("text", ["Okay, it's on.", "I've turned off the hall light.", "Done.",
                                  "Turned off the kitchen light.", "I switched the TV off.", "The lights are now off."])
def test_device_claims_still_need_a_tool(text):
    assert check(text, []) == "I didn't change anything."
