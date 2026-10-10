"""The frigate person mapper.

Frigate's face recognition runs centrally; this package turns the faces it
sees into room presence: who is in which room. It reports each room's
recognised people to the assistant router (so the voice assistant knows who
is in the room) and to Home Assistant (entities plus an event per change).

The parsing, state and payload logic are pure (this package's non-`__main__`
modules) and unit-tested; only `__main__` does I/O.
"""
