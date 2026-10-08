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
