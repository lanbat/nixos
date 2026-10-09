"""The gate against 106 real transcripts (labelled by hand, 2026-10-08).

The gate must never drop a real device command, and should catch most noise
before any model runs. Model accuracy itself is measured on the server with
the request log, since it needs the real model.
"""
import json
import pathlib

from assistant_router.gate import gate

CORPUS = json.loads((pathlib.Path(__file__).parent / "corpus.json").read_text())


def test_gate_never_drops_device_commands():
    dropped = [c["text"] for c in CORPUS if c["expect"] == "act" and gate(c["text"], "") == "reject"]
    assert dropped == []


def test_gate_catches_most_noise():
    noise = [c for c in CORPUS if c["expect"] == "reject"]
    caught = sum(gate(c["text"], "") == "reject" for c in noise)
    # 24 of 35 with rules that hold in general (2026-10-08); the rest is left
    # to the local model, which rejected most of it in the spike.
    assert caught >= 24, f"{caught}/{len(noise)}"
