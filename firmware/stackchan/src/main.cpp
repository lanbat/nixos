// Stack-chan as the face of a lanbat voice satellite (docs/stackchan.md).
//
// The robot is alive on its own: it blinks and breathes (M5Stack-Avatar),
// looks at the people its camera sees, looks around when nobody is there and
// dozes off when nobody has been for a while. When a face appears after an
// absence it notices: a glance, a nod, a warm glow.
//
// The Pi (pkgs/lva-stackchan) tells it over USB serial, one JSON object per
// line, what the voice assistant is doing:
//
//   {"mood": "neutral|listening|thinking|happy|sad|surprised|sleepy|confused|curious"}
//   {"look": "track|user|up|center"}
//   {"gesture": "perk|nod|shake|wiggle|tilt"}
//   {"mouth": 0.0-1.0}
//   {"caption": {"text": "...", "who": "user|assistant|status", "ms": 8000}}
//   {"timers": [{"id", "name", "remaining_s", "total_s", "ringing"}]}
//   {"sleep": true|false}
//   {"status": {"muted": bool, "online": bool}}
//   {"config": {"brightness": 0-255, "notice": bool}}
//   {"ping": 1}                       a heartbeat, every 3 s
//
// and hears back:
//
//   {"hello": {"fw": "1.0.0", "proto": 1}}   at boot and when the Pi returns
//   {"touch": "tap|stroke", "zone": "front|middle|back|screen"}
//   {"face": "new|lost"}
//   {"log": "..."}
//
// Without a line for 10 s it takes the Pi for gone and shows it.

#include <Arduino.h>
#include <ArduinoJson.h>
#include <Avatar.h>
#include <M5StackChan.h>
#include <M5Unified.h>

#include "lights.h"
#include "vision.h"

using namespace m5avatar;

namespace {

constexpr const char* kFirmware = "1.0.0";
constexpr int kProtocol = 1;

// Head limits, in tenths of a degree (the BSP's units). Narrower than the
// servos' own (yaw ±128°, pitch 0-90°) so a gesture on top of a glance never
// hits an end stop.
constexpr int kYawMin = -700, kYawMax = 700;
constexpr int kPitchMin = 50, kPitchMax = 800;
constexpr int kPitchRest = 300;  // looking slightly up, at someone in front
// Half the camera's field of view, in tenths of a degree (GC0308, ~60°).
constexpr float kHalfFovYaw = 300, kHalfFovPitch = 230;

constexpr uint32_t kPiTimeoutMs = 10000;
constexpr uint32_t kAbsenceForNoticeMs = 60000;  // gone this long, then seen: noticed
constexpr uint32_t kFaceLostMs = 2500;
constexpr uint32_t kDrowsyAfterMs = 5 * 60000;

Avatar avatar;
bool hasCamera = false;

// What the Pi said.
String mood = "neutral";
String look = "track";
bool asleep = false;
bool muted = false;
bool haOnline = true;
bool noticeGuests = true;
uint8_t brightness = 180;

String caption;
uint32_t captionUntil = 0;
String timerText;
float timerLeftShare = -1;
bool timerRinging = false;

// What the robot knows itself.
uint32_t lastLine = 0;
bool piPresent = false;
bool faceVisible = false;
uint32_t lastFaceSeen = 0;
uint32_t lastFaceFrame = 0;
float lastFaceYaw = 0, lastFacePitch = kPitchRest;
bool drowsy = false;
uint32_t nextWander = 0;
uint32_t touchDownZone = 0;

int targetYaw = 0, targetPitch = kPitchRest;

// A gesture is a few keyframes on top of where the head is pointed.
struct Keyframe {
  int yaw, pitch;  // offsets, tenths of a degree
  uint16_t ms;
};
const Keyframe* gesture = nullptr;
int gestureLength = 0, gestureStep = 0;
uint32_t gestureStepAt = 0;

const Keyframe kNod[] = {{0, -120, 220}, {0, 40, 200}, {0, 0, 250}};
const Keyframe kShake[] = {{-130, 0, 180}, {130, 0, 220}, {-130, 0, 220}, {0, 0, 200}};
const Keyframe kWiggle[] = {{-90, 30, 120}, {90, 30, 120}, {-90, 30, 120}, {90, 30, 120}, {0, 0, 200}};
const Keyframe kPerk[] = {{0, 90, 150}, {0, 60, 300}};
const Keyframe kTilt[] = {{110, 40, 400}, {110, 40, 900}, {0, 0, 400}};

// Both eyes the same way (Avatar's own saccades move them again in a while).
void gaze(float vertical, float horizontal) {
  avatar.setRightGaze(vertical, horizontal);
  avatar.setLeftGaze(vertical, horizontal);
}

void send(JsonDocument& doc) {
  serializeJson(doc, Serial);
  Serial.print('\n');
}

void sendHello() {
  JsonDocument doc;
  doc["hello"]["fw"] = kFirmware;
  doc["hello"]["proto"] = kProtocol;
  send(doc);
}

void sendEvent(const char* key, const char* value, const char* zone = nullptr) {
  JsonDocument doc;
  doc[key] = value;
  if (zone) doc["zone"] = zone;
  send(doc);
}

void startGesture(const Keyframe* frames, int length) {
  gesture = frames;
  gestureLength = length;
  gestureStep = 0;
  gestureStepAt = millis();
}

#define GESTURE(k) startGesture(k, sizeof(k) / sizeof(k[0]))

void pointHead(int yaw, int pitch, int speed) {
  targetYaw = constrain(yaw, kYawMin, kYawMax);
  targetPitch = constrain(pitch, kPitchMin, kPitchMax);
  M5StackChan.Motion.move(targetYaw, targetPitch, speed);
}

void setMood(const String& m) {
  mood = m;
  if (m == "happy") {
    avatar.setExpression(Expression::Happy);
  } else if (m == "sad") {
    avatar.setExpression(Expression::Sad);
  } else if (m == "thinking" || m == "confused" || m == "curious") {
    avatar.setExpression(Expression::Doubt);
  } else if (m == "sleepy") {
    avatar.setExpression(Expression::Sleepy);
  } else {
    avatar.setExpression(Expression::Neutral);
  }

  if (m == "listening") {
    lights::setScene(lights::Scene::Listening);
    gaze(0, 0);
  } else if (m == "thinking") {
    lights::setScene(lights::Scene::Thinking);
    gaze(-0.6f, 0.3f);  // eyes up and aside, as people do
  } else if (m == "confused") {
    lights::setScene(lights::Scene::Error);
  } else if (m == "surprised") {
    lights::setScene(lights::Scene::Greeting);
  } else if (m == "happy" && !piPresent) {
    lights::setScene(lights::Scene::Happy);
  } else if (m == "neutral" || m == "sleepy") {
    lights::setScene(lights::Scene::Off);
  }
}

void showText() {
  // A caption while one is due, otherwise the nearest timer.
  if (captionUntil && millis() < captionUntil) {
    avatar.setSpeechText(caption.c_str());
  } else {
    captionUntil = 0;
    avatar.setSpeechText(timerText.c_str());
  }
}

void setAsleep(bool a) {
  if (a == asleep) return;
  asleep = a;
  lights::setAsleep(a);
  vision::setPaused(a);
  if (a) {
    setMood("sleepy");
    pointHead(0, kPitchMin, 150);
    M5.Display.setBrightness(min<int>(brightness, 10));
  } else {
    drowsy = false;
    setMood("neutral");
    pointHead(0, kPitchRest, 300);
    M5.Display.setBrightness(brightness);
  }
}

String clock(int seconds) {
  char buf[16];
  if (seconds >= 3600)
    snprintf(buf, sizeof buf, "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60);
  else
    snprintf(buf, sizeof buf, "%d:%02d", seconds / 60, seconds % 60);
  return buf;
}

void handle(JsonDocument& doc) {
  if (doc["mood"].is<const char*>()) {
    String m = doc["mood"].as<const char*>();
    setMood(m);
    if (m == "listening" || m == "thinking") drowsy = false;
  }
  if (doc["look"].is<const char*>()) {
    look = doc["look"].as<const char*>();
    if (look == "user") {
      // At the last person seen, if recently; otherwise straight ahead.
      bool recent = lastFaceSeen && millis() - lastFaceSeen < 30000;
      pointHead(recent ? lastFaceYaw : 0, recent ? lastFacePitch : kPitchRest, 600);
    } else if (look == "up") {
      pointHead(targetYaw, targetPitch + 120, 250);
    } else if (look == "center") {
      pointHead(0, kPitchRest, 400);
    }
  }
  if (doc["gesture"].is<const char*>()) {
    String g = doc["gesture"].as<const char*>();
    if (g == "nod") GESTURE(kNod);
    else if (g == "shake") GESTURE(kShake);
    else if (g == "wiggle") GESTURE(kWiggle);
    else if (g == "perk") GESTURE(kPerk);
    else if (g == "tilt") GESTURE(kTilt);
  }
  if (!doc["mouth"].isNull()) {
    float level = constrain(doc["mouth"].as<float>(), 0.0f, 1.0f);
    avatar.setMouthOpenRatio(level);
    lights::setMouth(level);
    if (level > 0) lights::setScene(lights::Scene::Speaking);
  }
  if (doc["caption"].is<JsonObject>()) {
    caption = doc["caption"]["text"] | "";
    captionUntil = millis() + (doc["caption"]["ms"] | 8000);
    showText();
  } else if (doc["caption"].isNull() && !doc["caption"].isUnbound()) {
    captionUntil = 0;
    showText();
  }
  if (doc["timers"].is<JsonArray>()) {
    JsonArray timers = doc["timers"];
    timerText = "";
    timerLeftShare = -1;
    timerRinging = false;
    for (JsonObject t : timers) {  // the bridge sends the soonest first
      int left = t["remaining_s"] | 0, total = t["total_s"] | 0;
      bool ringing = t["ringing"] | false;
      if (timerLeftShare < 0) {
        String name = t["name"] | "";
        timerText = (ringing ? String("Time's up! ") : String("")) + (name.length() ? name + " " : "") +
                    (ringing ? "" : clock(left));
        timerLeftShare = total > 0 ? (float)left / total : 0;
      }
      timerRinging |= ringing;
    }
    lights::setTimer(timerLeftShare, timerRinging);
    showText();
  }
  if (doc["sleep"].is<bool>()) setAsleep(doc["sleep"].as<bool>());
  if (doc["status"].is<JsonObject>()) {
    muted = doc["status"]["muted"] | false;
    haOnline = doc["status"]["online"] | true;
    lights::setStatus(muted, haOnline);
  }
  if (doc["config"].is<JsonObject>()) {
    if (doc["config"]["brightness"].is<int>()) {
      brightness = doc["config"]["brightness"];
      M5.Display.setBrightness(brightness);
    }
    if (doc["config"]["notice"].is<bool>()) noticeGuests = doc["config"]["notice"];
  }
}

void readSerial() {
  static String line;
  while (Serial.available()) {
    char c = Serial.read();
    if (c == '\n') {
      JsonDocument doc;
      if (deserializeJson(doc, line) == DeserializationError::Ok && doc.is<JsonObject>()) {
        lastLine = millis();
        if (!piPresent) {
          piPresent = true;
          lights::setStatus(muted, haOnline);
          sendHello();  // the Pi answers with the whole state
        }
        handle(doc);
      }
      line = "";
    } else if (line.length() < 1024) {
      line += c;
    }
  }
  if (piPresent && millis() - lastLine > kPiTimeoutMs) {
    piPresent = false;
    lights::setStatus(muted, false);
    caption = "No Pi";
    captionUntil = millis() + 4000;
    showText();
    setMood("neutral");
    avatar.setMouthOpenRatio(0);
  }
}

const char* zoneName(int i) { return i == 0 ? "front" : i == 1 ? "middle" : "back"; }

void readTouch() {
  auto& ts = M5StackChan.TouchSensor;
  // Remember the zone pressed hardest while the head is touched.
  const auto& in = ts.getIntensities();
  int best = -1, bestLevel = 0;
  for (int i = 0; i < 3; i++)
    if (in[i] > bestLevel) best = i, bestLevel = in[i];
  if (best >= 0) touchDownZone = best;

  bool stroke = ts.wasSwiped();
  if (stroke) {
    sendEvent("touch", "stroke", zoneName(touchDownZone));
  } else if (ts.wasClicked()) {
    sendEvent("touch", "tap", zoneName(touchDownZone));
  }
  if (M5.Touch.getCount() && M5.Touch.getDetail(0).wasClicked()) {
    sendEvent("touch", "tap", "screen");
  }
  if ((stroke || ts.wasPressed()) && !piPresent) {
    // On its own it still enjoys being petted.
    setMood("happy");
    GESTURE(kNod);
  }
  if (drowsy && (stroke || ts.wasPressed())) {
    drowsy = false;
    setMood("neutral");
    pointHead(0, kPitchRest, 300);
  }
}

void follow() {
  uint32_t now = millis();
  if (!hasCamera || asleep) return;
  Sighting s = vision::latest();
  bool fresh = s.face && s.at != lastFaceFrame;

  if (fresh) {
    lastFaceFrame = s.at;
    bool wasAway = !lastFaceSeen || now - lastFaceSeen > kAbsenceForNoticeMs;
    lastFaceSeen = now;
    // Where the face is, in the head's angles: the camera turns with the head.
    lastFaceYaw = constrain(targetYaw + s.x * kHalfFovYaw, (float)kYawMin, (float)kYawMax);
    lastFacePitch = constrain(targetPitch + s.y * kHalfFovPitch, (float)kPitchMin, (float)kPitchMax);
    if (!faceVisible) {
      faceVisible = true;
      sendEvent("face", "new");
      if (drowsy) {
        drowsy = false;
        setMood("neutral");
      }
      if (wasAway && noticeGuests && look == "track" && mood == "neutral") {
        // Someone came in: look at them, a glow, a nod.
        avatar.setExpression(Expression::Happy);
        lights::setScene(lights::Scene::Greeting);
        pointHead(lastFaceYaw, lastFacePitch, 700);
        GESTURE(kNod);
      }
    }
    if (look == "track" && !gesture) {
      // Follow gently; ignore small offsets so the head isn't nervous.
      if (fabsf(s.x) > 0.12f || fabsf(s.y) > 0.15f) {
        pointHead(targetYaw + s.x * kHalfFovYaw * 0.6f, targetPitch + s.y * kHalfFovPitch * 0.6f, 350);
      }
      gaze(-s.y * 0.5f, s.x * 0.5f);
    }
  } else if (faceVisible && now - lastFaceSeen > kFaceLostMs) {
    faceVisible = false;
    sendEvent("face", "lost");
    if (mood == "neutral") avatar.setExpression(Expression::Neutral);
  }
}

void wander() {
  uint32_t now = millis();
  if (asleep || look != "track" || faceVisible || gesture || mood != "neutral") return;
  if (!drowsy && now - lastFaceSeen > kDrowsyAfterMs) {  // since boot, if nobody yet
    // Nobody for a while: it dozes, head down, until someone shows up.
    drowsy = true;
    avatar.setExpression(Expression::Sleepy);
    pointHead(0, kPitchMin + 100, 120);
    return;
  }
  if (drowsy || now < nextWander) return;
  // Glance somewhere else now and then, like something alive.
  nextWander = now + random(6000, 15000);
  pointHead(random(-450, 450), kPitchRest + random(-80, 150), 200);
  gaze(random(-30, 30) / 100.0f, random(-50, 50) / 100.0f);
}

void runGesture() {
  if (!gesture) return;
  uint32_t now = millis();
  if (now - gestureStepAt < (gestureStep ? gesture[gestureStep - 1].ms : 0)) return;
  if (gestureStep >= gestureLength) {
    gesture = nullptr;
    M5StackChan.Motion.move(targetYaw, targetPitch, 500);
    return;
  }
  const Keyframe& k = gesture[gestureStep++];
  gestureStepAt = now;
  M5StackChan.Motion.move(constrain(targetYaw + k.yaw, kYawMin, kYawMax),
                          constrain(targetPitch + k.pitch, kPitchMin, kPitchMax), 850);
}

}  // namespace

void setup() {
  M5StackChan.begin();  // M5Unified, servo power, touch, LEDs
  Serial.begin(115200);
  M5.Display.setBrightness(brightness);

  avatar.init();
  avatar.setSpeechFont(&fonts::efontCN_12);

  hasCamera = vision::begin();
  pointHead(0, kPitchRest, 300);
  randomSeed(esp_random());

  sendHello();
  if (!hasCamera) {
    JsonDocument doc;
    doc["log"] = "no camera: not looking at people";
    send(doc);
  }
}

void loop() {
  M5StackChan.update();  // touch sensor (and M5.update)
  readSerial();
  readTouch();
  follow();
  wander();
  runGesture();
  if (captionUntil && millis() > captionUntil) showText();
  lights::update();

  // Once, 15 s after boot: whether the camera delivers frames.
  static bool reported = false;
  if (!reported && hasCamera && millis() > 15000) {
    reported = true;
    JsonDocument doc;
    doc["log"] = String("camera: ") + vision::frameCount() + " frames in the first 15 s";
    send(doc);
  }
  delay(10);
}
