from assistant_router.people import People

NAMES = {"kiril": "Kiril", "maria": "Maria", "ivo": "Ivo"}


def test_nothing_known_says_nothing():
    p = People(NAMES)
    assert p.line("Kitchen", now=0.0) is None
    assert p.line("Kitchen", now=0.0, voice=None) is None


def test_voice_alone_names_the_speaker():
    line = People(NAMES).line("Kitchen", now=0.0, voice=("kiril", 0.9))
    assert "talking to Kiril" in line and "by voice" in line
    assert "never" in line  # the hint is never authority


def test_a_weak_voice_match_is_no_match():
    assert People(NAMES).line("Kitchen", now=0.0, voice=("kiril", 0.4)) is None


def test_voice_and_face_agreeing():
    p = People(NAMES)
    p.observe("Kitchen", "face", "kiril", 0.9, now=10.0)
    line = p.line("kitchen", now=12.0, voice=("kiril", 0.8))
    assert "talking to Kiril" in line and "voice and face" in line


def test_voice_and_face_disagreeing_names_nobody():
    p = People(NAMES)
    p.observe("Kitchen", "face", "maria", 0.9, now=10.0)
    line = p.line("Kitchen", now=12.0, voice=("kiril", 0.8))
    assert "talking to" not in line
    assert "don't know who is speaking" in line


def test_one_face_in_front_of_the_robot_is_the_speaker():
    p = People(NAMES)
    p.observe("Kitchen", "face", "maria", 0.9, now=10.0)
    assert "talking to Maria" in p.line("Kitchen", now=11.0)


def test_two_faces_name_nobody():
    p = People(NAMES)
    p.observe("Kitchen", "face", "maria", 0.9, now=10.0)
    p.observe("Kitchen", "face", "ivo", 0.9, now=10.0)
    line = p.line("Kitchen", now=11.0)
    assert "talking to" not in line
    assert "Maria" in line and "Ivo" in line


def test_phones_are_nearby_not_speaking():
    p = People(NAMES)
    p.observe("Kitchen", "phone", "maria", 1.0, now=0.0)
    line = p.line("Kitchen", now=30.0, voice=("kiril", 0.9))
    assert "talking to Kiril" in line
    assert "Maria is nearby" in line


def test_evidence_expires():
    p = People(NAMES)
    p.observe("Kitchen", "face", "kiril", 0.9, now=0.0)
    p.observe("Kitchen", "phone", "maria", 1.0, now=0.0)
    assert p.line("Kitchen", now=30.0) is not None      # the phone still counts
    assert "Kiril" not in p.line("Kitchen", now=30.0)   # the face is 30 s old
    assert p.line("Kitchen", now=200.0) is None         # so is the phone, after 2 minutes


def test_other_rooms_are_other_rooms():
    p = People(NAMES)
    p.observe("Office", "face", "kiril", 0.9, now=0.0)
    assert p.line("Kitchen", now=1.0) is None


def test_unknown_people_and_sources_are_dropped():
    p = People(NAMES)
    p.observe("Kitchen", "face", "mallory", 0.99, now=0.0)
    p.observe("Kitchen", "smell", "kiril", 0.99, now=0.0)
    p.observe("Kitchen", "face", "kiril", "very", now=0.0)
    assert p.line("Kitchen", now=1.0) is None
    assert People(NAMES).line("Kitchen", now=0.0, voice=("mallory", 0.99)) is None


def test_a_face_that_left_is_forgotten():
    p = People(NAMES)
    p.observe("Kitchen", "face", "kiril", 0.9, now=0.0)
    p.forget_faces("Kitchen")
    assert p.line("Kitchen", now=1.0) is None
