from assistant_router.state import State


def test_last_reply_expires():
    s = State(echo_seconds=30)
    s.remember_reply("dev", "Done.", now=100)
    assert s.last_reply("dev", now=120) == "Done."
    assert s.last_reply("dev", now=131) == ""
    assert s.last_reply("other", now=120) == ""


def test_tier_is_per_conversation_and_expires():
    s = State(turn_seconds=120)
    s.set_tier("c1", "cloud", now=0)
    assert s.tier("c1", now=60) == "cloud"
    assert s.tier("c2", now=60) is None
    assert s.tier("c1", now=121) is None
