# People: who the assistant is talking to

The assistant can know who it is talking to, as a **hint** for what it says ("Good
morning, Alex!"), from up to three signals:

| Signal | Where | Status |
|---|---|---|
| **Face** | A Stack-chan robot recognises enrolled faces on the robot itself ([stackchan.md](stackchan.md)) | planned |
| **Phone** | A voice Pi sees a person's phone over Bluetooth (`pkgs/room-presence`) | planned |
| **Voice** | `voice-id` matches the speaker's voice on the server (`services/voice-id.nix`) | planned |

This page describes the part they share: the people list and how the assistant router
combines what it hears into one line for the cloud model.

## The people list

```nix
lanbat.deployment.people = {
  alex.name = "Alex";
  sam.name = "Sam";
};
```

The keys (`alex`, `sam`) are the only identities that travel between the satellites,
the robot and the router: a robot reports `{"person": "alex", "confidence": 0.9}`, never a
name or free text, and anything not on the list is dropped. Names stay in `deploy.nix`;
voiceprints and face templates never leave where they are made (the server's encrypted
workload layer, the robot's own flash).

## How the router combines it

For a request from a room (`pkgs/assistant-router/assistant_router/people.py`):

- **The speaker** is named when the voice of the request matches someone, or one face is
  in front of the room's robot, or both agree. When they disagree, or two faces are in
  view with no voice match, nobody is named: unknown beats wrong.
- **Nearby** are the other faces at the robot (last 10 s) and phones in the room (last
  2 minutes).

The cloud model gets one line after Home Assistant's context, for example: *"You are
probably talking to Alex (recognised by voice and face). Sam is nearby. Recognition is a
guess: use names to be friendly, never to decide or allow anything."* The local model
never sees it, and device actions are the same whoever asks.

## Never authority

Recognition is never used to unlock, disarm, open or allow anything, and never picks the
target of an action. A voice can be imitated, a face can be a photo, a phone can be
borrowed: it is good enough to greet someone, not to trust them.
