"""The Stack-chan bridge's decisions (pkgs/lva-stackchan), without a device or LVA.

Brain turns Linux Voice Assistant events, the device's messages and the clock
into lines for the device and commands for LVA; these feed it scripted turns
and check what comes out.

Run with: nix build .#checks.x86_64-linux.stackchan-bridge
"""
import os
import sys
import time
import unittest

os.environ["TZ"] = "UTC"
time.tzset()
sys.path.insert(0, sys.argv.pop(1))

from stackchan_bridge import Brain, Config, envelope_level  # noqa: E402

NOON = 1_800_000_000 - 1_800_000_000 % 86400 + 12 * 3600  # 12:00 UTC
MIDNIGHT = NOON + 12 * 3600  # 00:00 UTC, the next day


def device(actions):
    return [a[1] for a in actions if a[0] == "device"]


def lva(actions):
    return [a[1] for a in actions if a[0] == "lva"]


def merged(actions):
    out = {}
    for line in device(actions):
        out.update(line)
    return out


class Turn(unittest.TestCase):
    def setUp(self):
        self.brain = Brain(Config(), now=NOON)

    def test_a_turn_from_wake_word_to_idle(self):
        b = self.brain
        wake = merged(b.on_lva("wake_word_detected", {}, NOON))
        self.assertEqual(wake["mood"], "listening")
        self.assertEqual(wake["look"], "user")
        self.assertEqual(wake["caption"]["who"], "status")

        said = merged(b.on_lva("stt_text", {"text": "what time is it"}, NOON))
        self.assertEqual(said["caption"], {"text": "what time is it", "who": "user", "ms": 8000})

        thinking = merged(b.on_lva("thinking", {}, NOON))
        self.assertEqual(thinking["mood"], "thinking")
        self.assertEqual(thinking["look"], "up")

        reply = b.on_lva("tts_text", {"text": "It is noon."}, NOON)
        self.assertEqual(merged(reply)["caption"]["who"], "assistant")
        self.assertEqual(merged(reply)["mood"], "happy")

        self.assertIn(("mouth", True), b.on_lva("tts_speaking", {}, NOON))
        finished = b.on_lva("tts_finished", {}, NOON)
        self.assertIn(("mouth", False), finished)
        self.assertEqual(merged(finished)["mouth"], 0)

        idle = merged(b.on_lva("idle", {}, NOON))
        self.assertEqual(idle["mood"], "neutral")
        self.assertEqual(idle["look"], "track")
        self.assertFalse(b.in_turn)

    def test_reply_moods(self):
        b = self.brain
        cases = {
            "Sorry, I couldn't find a device called kitchen.": "sad",
            "I can't do that.": "sad",
            "Wow, that's a big number!": "happy",
            "Turned on the light.": "happy",
            "Which light do you mean?": "curious",
        }
        for text, mood in cases.items():
            with self.subTest(text=text):
                self.assertEqual(merged(b.on_lva("tts_text", {"text": text}, NOON))["mood"], mood)

    def test_errors_and_connection(self):
        b = self.brain
        err = merged(b.on_lva("pipeline_error", {"reason": "stt-no-text"}, NOON))
        self.assertEqual(err["mood"], "confused")
        self.assertEqual(err["gesture"], "shake")
        off = merged(b.on_lva("disconnected", {}, NOON))
        self.assertEqual(off["status"]["online"], False)
        on = merged(b.on_lva("zeroconf", {"status": "connected"}, NOON))
        self.assertEqual(on["status"]["online"], True)

    def test_muted(self):
        b = self.brain
        self.assertEqual(merged(b.on_lva("muted", {"muted": True}, NOON))["status"]["muted"], True)
        self.assertEqual(merged(b.on_lva("muted", {"muted": False}, NOON))["status"]["muted"], False)

    def test_snapshot_restores_status(self):
        snap = merged(self.brain.on_lva("snapshot", {"muted": True, "ha_connected": False}, NOON))
        self.assertEqual(snap["status"], {"muted": True, "online": False})

    def test_captions_can_be_turned_off(self):
        b = Brain(Config(captions=False), now=NOON)
        for event, data in [("wake_word_detected", {}), ("stt_text", {"text": "hi"}), ("tts_text", {"text": "Hello."})]:
            self.assertNotIn("caption", merged(b.on_lva(event, data, NOON)))

    def test_continued_conversation_stays_in_turn(self):
        b = self.brain
        b.on_lva("wake_word_detected", {}, NOON)
        b.on_lva("tts_finished", {}, NOON)
        again = merged(b.on_lva("listening", {}, NOON))
        self.assertEqual(again["mood"], "listening")
        self.assertTrue(b.in_turn)


class Touch(unittest.TestCase):
    def test_tap_starts_a_conversation(self):
        b = Brain(Config(), now=NOON)
        out = b.on_device({"touch": "tap", "zone": "middle"}, NOON)
        self.assertEqual(lva(out), [{"command": "start_listening"}])

    def test_tap_during_a_turn_stops_it(self):
        b = Brain(Config(), now=NOON)
        b.on_lva("wake_word_detected", {}, NOON)
        out = b.on_device({"touch": "tap", "zone": "front"}, NOON)
        self.assertEqual(lva(out), [{"command": "stop_pipeline"}])

    def test_any_touch_silences_a_ringing_timer(self):
        b = Brain(Config(), now=NOON)
        b.on_lva("timer_ringing", {"id": "t1", "name": "", "total_seconds": 60, "seconds_left": 0}, NOON)
        out = b.on_device({"touch": "stroke", "zone": "back"}, NOON)
        self.assertEqual(lva(out), [{"command": "stop_timer_ringing"}])

    def test_stroke_is_affection_not_a_command(self):
        b = Brain(Config(), now=NOON)
        out = b.on_device({"touch": "stroke", "zone": "back"}, NOON)
        self.assertEqual(lva(out), [])
        self.assertEqual(merged(out)["mood"], "happy")

    def test_touch_to_talk_can_be_turned_off(self):
        b = Brain(Config(touch_to_talk=False), now=NOON)
        out = b.on_device({"touch": "tap", "zone": "middle"}, NOON)
        self.assertEqual(lva(out), [])
        self.assertEqual(merged(out)["mood"], "happy")


class Timers(unittest.TestCase):
    def timer(self, left, tid="t1", total=300, name="pasta"):
        return {"id": tid, "name": name, "total_seconds": total, "seconds_left": left}

    def test_timer_is_shown_and_counted_down_locally(self):
        b = Brain(Config(), now=NOON)
        shown = merged(b.on_lva("timer_ticking", self.timer(300), NOON))
        self.assertEqual(
            shown["timers"],
            [{"id": "t1", "name": "pasta", "remaining_s": 300, "total_s": 300, "ringing": False}],
        )
        later = merged(b.tick(NOON + 100))
        self.assertEqual(later["timers"][0]["remaining_s"], 200)

    def test_ringing_then_stopped(self):
        b = Brain(Config(), now=NOON)
        b.on_lva("timer_ticking", self.timer(5), NOON)
        ring = merged(b.on_lva("timer_ringing", self.timer(0), NOON + 5))
        self.assertTrue(ring["timers"][0]["ringing"])
        self.assertEqual(ring["mood"], "surprised")
        self.assertEqual(ring["gesture"], "wiggle")
        done = merged(b.on_lva("idle", {}, NOON + 9))
        self.assertEqual(done["timers"], [])

    def test_idle_in_the_middle_of_a_turn_is_a_cancel(self):
        # LVA reports a cancelled timer as a bare idle, which arrives between
        # the transcript and the reply.
        b = Brain(Config(), now=NOON)
        b.on_lva("timer_ticking", self.timer(300), NOON)
        b.on_lva("wake_word_detected", {}, NOON + 10)
        b.on_lva("stt_text", {"text": "cancel the timer"}, NOON + 11)
        out = merged(b.on_lva("idle", {}, NOON + 12))
        self.assertEqual(out["timers"], [])
        self.assertTrue(b.in_turn)  # the reply is still to come

    def test_idle_after_a_turn_keeps_the_timer(self):
        b = Brain(Config(), now=NOON)
        b.on_lva("wake_word_detected", {}, NOON)
        b.on_lva("stt_text", {"text": "set a timer for 5 minutes"}, NOON)
        b.on_lva("timer_ticking", self.timer(300), NOON)
        b.on_lva("tts_text", {"text": "Timer set."}, NOON)
        b.on_lva("tts_finished", {}, NOON)
        out = merged(b.on_lva("idle", {}, NOON + 1))
        self.assertEqual(len(out.get("timers", b.timers_payload(NOON + 1))), 1)

    def test_a_timer_that_never_rang_is_dropped_a_minute_after_it_ended(self):
        b = Brain(Config(), now=NOON)
        b.on_lva("timer_ticking", self.timer(10), NOON)
        self.assertEqual(len(b.timers_payload(NOON + 30)), 1)
        self.assertEqual(merged(b.tick(NOON + 75))["timers"], [])


class Night(unittest.TestCase):
    def test_falls_asleep_at_night_and_wakes_in_the_morning(self):
        b = Brain(Config(night_start="23:00", night_end="07:00"), now=NOON)
        self.assertEqual(merged(b.tick(MIDNIGHT))["sleep"], True)
        self.assertEqual(b.tick(MIDNIGHT + 60), [])  # only on the change
        self.assertEqual(merged(b.tick(MIDNIGHT + 8 * 3600))["sleep"], False)

    def test_a_turn_wakes_it_and_it_goes_back_to_sleep(self):
        b = Brain(Config(night_start="23:00", night_end="07:00"), now=MIDNIGHT)
        self.assertEqual(merged(b.on_lva("wake_word_detected", {}, MIDNIGHT))["sleep"], False)
        self.assertEqual(merged(b.on_lva("idle", {}, MIDNIGHT + 10))["sleep"], True)

    def test_no_night_when_unset(self):
        b = Brain(Config(night_start="", night_end=""), now=MIDNIGHT)
        self.assertNotIn("sleep", merged(b.tick(MIDNIGHT + 60)))


class Device(unittest.TestCase):
    def test_hello_gets_the_whole_state(self):
        b = Brain(Config(brightness=150), now=NOON)
        b.on_lva("muted", {"muted": True}, NOON)
        state = merged(b.on_device({"hello": {"fw": "1.0.0", "proto": 1}}, NOON))
        self.assertEqual(state["status"]["muted"], True)
        self.assertEqual(state["config"]["brightness"], 150)
        self.assertEqual(state["mood"], "neutral")
        self.assertEqual(state["sleep"], False)
        self.assertIn("timers", state)

    def test_wrong_protocol_is_reported(self):
        b = Brain(Config(), now=NOON)
        out = b.on_device({"hello": {"fw": "9.0.0", "proto": 99}}, NOON)
        self.assertTrue(any(a[0] == "log" and "protocol" in a[1] for a in out))


class Router(unittest.TestCase):
    """The assistant router's side (pkgs/assistant-router body.py)."""

    def router(self, actions):
        return [a[1] for a in actions if a[0] == "router"]

    def test_the_routers_mood_wins_over_the_guess(self):
        b = Brain(Config(), now=NOON)
        b.on_lva("wake_word_detected", {}, NOON)
        acted = merged(b.on_router({"act": {"mood": "excited", "gesture": "dance"}}, NOON + 1))
        self.assertEqual(acted["mood"], "excited")
        self.assertEqual(acted["gesture"], "dance")
        # "Sorry" would make the guess sad; the router said excited.
        reply = merged(b.on_lva("tts_text", {"text": "Sorry, I just love dancing!"}, NOON + 2))
        self.assertEqual(reply["mood"], "excited")

    def test_the_routers_mood_is_forgotten_after_a_while(self):
        b = Brain(Config(), now=NOON)
        b.on_router({"act": {"mood": "excited"}}, NOON)
        self.assertEqual(merged(b.on_lva("tts_text", {"text": "Sorry."}, NOON + 30))["mood"], "sad")

    def test_look_commands(self):
        b = Brain(Config(), now=NOON)
        self.assertEqual(merged(b.on_router({"act": {"look": "user"}}, NOON))["look"], "user")
        self.assertEqual(merged(b.on_router({"act": {"gesture": "look_at_user"}}, NOON))["look"], "user")
        self.assertEqual(merged(b.on_router({"act": {"gesture": "look_around"}}, NOON))["gesture"], "look_around")

    def test_unknown_values_are_ignored(self):
        b = Brain(Config(), now=NOON)
        self.assertEqual(b.on_router({"act": {"mood": "furious", "gesture": "backflip", "look": "away"}}, NOON), [])
        self.assertEqual(b.on_router({"hello": 1}, NOON), [])

    def test_go_to_sleep_by_day_lasts_until_the_night_changes(self):
        b = Brain(Config(night_start="23:00", night_end="07:00"), now=NOON)
        b.on_lva("wake_word_detected", {}, NOON)
        b.on_router({"act": {"sleep": True}}, NOON + 1)
        self.assertEqual(merged(b.on_lva("idle", {}, NOON + 3))["sleep"], True)  # after the reply
        self.assertNotIn("sleep", merged(b.tick(NOON + 60)))  # still day: it stays asleep
        self.assertEqual(merged(b.tick(MIDNIGHT))["sleep"], True)
        self.assertEqual(merged(b.tick(MIDNIGHT + 8 * 3600))["sleep"], False)

    def test_wake_up_at_night(self):
        b = Brain(Config(night_start="23:00", night_end="07:00"), now=MIDNIGHT)
        b.on_lva("wake_word_detected", {}, MIDNIGHT)
        b.on_router({"act": {"sleep": False}}, MIDNIGHT + 1)
        self.assertNotIn("sleep", merged(b.on_lva("idle", {}, MIDNIGHT + 3)))
        self.assertFalse(b.asleep)

    def test_presence_is_reported_on_change(self):
        b = Brain(Config(), now=NOON)
        self.assertEqual(self.router(b.on_device({"face": "new"}, NOON)),
                         [{"state": {"present": True, "present_since_s": 0, "asleep": False}}])
        self.assertEqual(self.router(b.on_device({"face": "new"}, NOON + 1)), [])
        self.assertEqual(self.router(b.on_device({"face": "lost"}, NOON + 90)),
                         [{"state": {"present": False, "present_since_s": 0, "asleep": False}}])

    def test_state_on_connect(self):
        b = Brain(Config(), now=NOON)
        b.on_device({"face": "new"}, NOON)
        self.assertEqual(b.router_state(NOON + 125), {"present": True, "present_since_s": 125, "asleep": False})


class Nap(unittest.TestCase):
    """The robot naps by itself when nobody has been around (firmware)."""

    def router(self, actions):
        return [a[1] for a in actions if a[0] == "router"]

    def test_the_nap_time_goes_to_the_robot(self):
        b = Brain(Config(nap_after_s=600), now=NOON)
        state = merged(b.on_device({"hello": {"fw": "1.0.0", "proto": 1}}, NOON))
        self.assertEqual(state["config"]["nap_after_s"], 600)
        self.assertEqual(Config().nap_after_s, 900)
        self.assertEqual(Config.from_env({"NAP_AFTER_S": "0"}).nap_after_s, 0)

    def test_a_nap_is_sleep_to_the_router(self):
        b = Brain(Config(), now=NOON)
        self.assertEqual(self.router(b.on_device({"rest": "nap"}, NOON)),
                         [{"state": {"present": False, "present_since_s": 0, "asleep": True}}])
        self.assertEqual(self.router(b.on_device({"rest": "nap"}, NOON + 1)), [])
        self.assertEqual(self.router(b.on_device({"rest": "awake"}, NOON + 60)),
                         [{"state": {"present": False, "present_since_s": 0, "asleep": False}}])
        self.assertEqual(b.on_device({"rest": "snoring"}, NOON + 61), [])


class Envelope(unittest.TestCase):
    def test_silence_is_closed_and_speech_opens(self):
        quiet = b"\x00\x00" * 400
        loud = (b"\x00\x40" + b"\x00\xc0") * 200  # +/-16384
        self.assertEqual(envelope_level(quiet), 0.0)
        self.assertGreater(envelope_level(loud), 0.4)
        self.assertLessEqual(envelope_level(loud), 1.0)


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0], "-v"])
