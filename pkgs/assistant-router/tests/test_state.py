from assistant_router.state import State


def test_last_reply_expires():
    s = State(echo_seconds=30)
    s.remember_reply("dev", "Done.", now=100)
    assert s.last_reply("dev", now=120) == "Done."
    assert s.last_reply("dev", now=131) == ""
    assert s.last_reply("other", now=120) == ""


def test_pending_acts_are_keyed_by_tool_call_and_expire():
    s = State(pending_seconds=60)
    s.add_pending("call_a", "act-a", now=0)
    assert s.take_pending(["call_x"], now=10) is None
    assert s.take_pending(["call_a"], now=10) == "act-a"
    assert s.take_pending(["call_a"], now=11) is None
    s.add_pending("call_b", "act-b", now=0)
    s.add_pending("call_c", "act-c", now=100)  # writing prunes call_b, older than 60 s
    assert "call_b" not in s._pending
