#include "vision.h"

#include <M5Unified.h>
#include <esp_camera.h>
#include <esp_log.h>

#include "human_face_detect.hpp"

// esp32-camera's own SCCB teardown (private header): it removes the sensor
// from the I2C bus the driver opened and deletes the bus.
extern "C" int SCCB_Deinit(void);

namespace {

// M5Stack's GC0308 configuration for the CoreS3 (M5CoreS3's GC0308.cpp). The
// sensor has its own clock (no XCLK); its SCCB is the internal I2C bus.
camera_config_t cameraConfig() {
  camera_config_t c = {};
  c.pin_pwdn = -1;
  c.pin_reset = -1;
  c.pin_xclk = -1;
  c.pin_sccb_sda = 12;
  c.pin_sccb_scl = 11;
  c.pin_d7 = 47;
  c.pin_d6 = 48;
  c.pin_d5 = 16;
  c.pin_d4 = 15;
  c.pin_d3 = 42;
  c.pin_d2 = 41;
  c.pin_d1 = 40;
  c.pin_d0 = 39;
  c.pin_vsync = 46;
  c.pin_href = 38;
  c.pin_pclk = 45;
  c.xclk_freq_hz = 20000000;
  c.ledc_timer = LEDC_TIMER_0;
  c.ledc_channel = LEDC_CHANNEL_0;
  c.pixel_format = PIXFORMAT_RGB565;
  c.frame_size = FRAMESIZE_QVGA;
  c.jpeg_quality = 0;
  c.fb_count = 2;
  c.fb_location = CAMERA_FB_IN_PSRAM;
  c.grab_mode = CAMERA_GRAB_LATEST;
  c.sccb_i2c_port = -1;
  return c;
}

SemaphoreHandle_t lock;
Sighting current;
volatile bool paused = false;
volatile uint32_t frames = 0;
// Debug view: the camera image on the robot's own screen, with the
// detector's boxes, and counts for the Pi's journal.
volatile bool preview = false;
volatile uint32_t candidatesSeen = 0, trackedFrames = 0;
volatile float bestScore = 0;

// The image is mirrored: a face on the robot's left is on the frame's right.
constexpr float kMirrorX = -1.0f;
constexpr uint32_t kFramePeriodMs = 150;

// A detection counts as a face once it has turned up in about the same place
// in kHitsNeeded frames in a row, so one stray hit doesn't move the head.
constexpr int kHitsNeeded = 2;
constexpr float kSamePlace = 0.25f;  // share of the frame width
constexpr uint32_t kHitGapMs = 700;

void detectTask(void*) {
  // Espressif's human_face_detect (esp-dl 3, the two-stage MSR+MNP model in
  // flash), with the thresholds StackChan-CustomFW uses on this camera. The
  // detector bundled with Arduino 2.0.x scored a face here 0.10-0.15 and
  // found it in about one frame in a hundred (2026-10-09).
  HumanFaceDetect detector;
  detector.set_score_thr(0.25f, 0);
  detector.set_score_thr(0.3f, 1);
  float trackX = 0, trackY = 0;
  int hits = 0;
  uint32_t lastHit = 0;

  for (;;) {
    if (paused) {
      vTaskDelay(pdMS_TO_TICKS(500));
      continue;
    }
    uint32_t started = millis();
    camera_fb_t* fb = esp_camera_fb_get();
    if (!fb) {
      vTaskDelay(pdMS_TO_TICKS(200));
      continue;
    }
    frames++;
    // The camera sends RGB565 high byte first.
    dl::image::img_t img = {fb->buf, (uint16_t)fb->width, (uint16_t)fb->height,
                            dl::image::DL_IMAGE_PIX_TYPE_RGB565BE};
    auto& candidates = detector.run(img);
    candidatesSeen += candidates.size();

    // The strongest candidate, in frame shares (0..1).
    const dl::detect::result_t* best = nullptr;
    for (auto& c : candidates)
      if (!best || c.score > best->score) best = &c;
    float bx = 0, by = 0, bw = 0;
    if (best) {
      bx = (best->box[0] + best->box[2]) / 2.0f / fb->width;
      by = (best->box[1] + best->box[3]) / 2.0f / fb->height;
      bw = (float)(best->box[2] - best->box[0]) / fb->width;
      if (best->score > bestScore) bestScore = best->score;
      uint32_t now = millis();
      bool near = hits > 0 && now - lastHit < kHitGapMs && fabsf(bx - trackX) < kSamePlace &&
                  fabsf(by - trackY) < kSamePlace;
      hits = near ? hits + 1 : 1;
      trackX = bx;
      trackY = by;
      lastHit = now;
    } else if (millis() - lastHit > kHitGapMs) {
      hits = 0;
    }

    if (preview) {
      M5.Display.startWrite();
      M5.Display.pushImage(0, 0, fb->width, fb->height, (uint16_t*)fb->buf);
      for (auto& c : candidates)
        M5.Display.drawRect(c.box[0], c.box[1], c.box[2] - c.box[0], c.box[3] - c.box[1],
                            &c == best && hits >= kHitsNeeded ? TFT_GREEN : TFT_YELLOW);
      M5.Display.endWrite();
    }
    esp_camera_fb_return(fb);

    Sighting s;
    s.at = millis();
    if (best && hits >= kHitsNeeded) {
      trackedFrames++;
      s.face = true;
      s.x = kMirrorX * (bx * 2 - 1);
      s.y = -(by * 2 - 1);
      s.size = bw;
    }

    xSemaphoreTake(lock, portMAX_DELAY);
    current = s;
    xSemaphoreGive(lock);

    uint32_t spent = millis() - started;
    if (spent < kFramePeriodMs) vTaskDelay(pdMS_TO_TICKS(kFramePeriodMs - spent));
  }
}

}  // namespace

namespace vision {

bool begin() {
  lock = xSemaphoreCreateMutex();
  // The driver's DMA task logs a warning for a short or overflowing frame,
  // and its small stack overflows doing it (stack canary, cam_task). A bad
  // frame is only skipped; keep it quiet.
  esp_log_level_set("cam_hal", ESP_LOG_NONE);
  esp_log_level_set("camera", ESP_LOG_ERROR);
  // The camera's SCCB shares the internal I2C bus (PMIC, touch, the body's
  // IO expander and head sensor). It is needed only to set the sensor up:
  // M5Unified lets go of the bus, the camera driver opens it and configures
  // the sensor, closes it again (SCCB_Deinit; ESP-IDF 5 allows one driver per
  // port), and the bus goes back to M5Unified. Frames come over the parallel
  // port.
  M5.In_I2C.release();
  camera_config_t config = cameraConfig();
  esp_err_t err = esp_camera_init(&config);
  if (err == ESP_OK) {
    if (sensor_t* sensor = esp_camera_sensor_get()) {
      sensor->set_hmirror(sensor, 0);
    }
  }
  SCCB_Deinit();
  M5.In_I2C.begin(I2C_NUM_1, 12, 11);
  if (err != ESP_OK) {
    return false;
  }
  xTaskCreatePinnedToCore(detectTask, "vision", 12288, nullptr, 1, nullptr, 0);
  return true;
}

Sighting latest() {
  xSemaphoreTake(lock, portMAX_DELAY);
  Sighting s = current;
  xSemaphoreGive(lock);
  return s;
}

void setPaused(bool p) { paused = p; }

uint32_t frameCount() { return frames; }

void setPreview(bool on) { preview = on; }

String stats() {
  char buf[120];
  snprintf(buf, sizeof buf, "camera: %u frames, %u candidates (best %.2f), %u frames with a face",
           (unsigned)frames, (unsigned)candidatesSeen, (double)bestScore, (unsigned)trackedFrames);
  candidatesSeen = trackedFrames = 0;
  bestScore = 0;
  return buf;
}

}  // namespace vision
