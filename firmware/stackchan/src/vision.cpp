#include "vision.h"

#include <M5Unified.h>
#include <driver/i2c.h>
#include <esp_camera.h>

#include "human_face_detect_mnp01.hpp"
#include "human_face_detect_msr01.hpp"

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

// The image is mirrored: a face on the robot's left is on the frame's right.
constexpr float kMirrorX = -1.0f;
constexpr uint32_t kFramePeriodMs = 150;

void detectTask(void*) {
  // esp-dl's two-stage detector, with the thresholds of Espressif's
  // CameraWebServer example.
  HumanFaceDetectMSR01 stage1(0.1f, 0.5f, 10, 0.2f);
  HumanFaceDetectMNP01 stage2(0.5f, 0.3f, 5);

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
    std::vector<int> shape = {(int)fb->height, (int)fb->width, 3};
    auto& candidates = stage1.infer((uint16_t*)fb->buf, shape);
    auto& faces = stage2.infer((uint16_t*)fb->buf, shape, candidates);

    Sighting s;
    s.at = millis();
    float bestWidth = 0;
    for (auto& f : faces) {
      float w = f.box[2] - f.box[0];
      if (w <= bestWidth) continue;
      bestWidth = w;
      float cx = (f.box[0] + f.box[2]) / 2.0f / fb->width;
      float cy = (f.box[1] + f.box[3]) / 2.0f / fb->height;
      s.face = true;
      s.x = kMirrorX * (cx * 2 - 1);
      s.y = -(cy * 2 - 1);
      s.size = w / fb->width;
    }
    esp_camera_fb_return(fb);

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
  // The camera's SCCB shares the internal I2C bus (PMIC, touch, the body's
  // IO expander and head sensor). It is needed only to set the sensor up:
  // M5Unified lets go of the bus, the camera driver configures the sensor,
  // then the bus goes back to M5Unified. Frames come over the parallel port.
  M5.In_I2C.release();
  camera_config_t config = cameraConfig();
  esp_err_t err = esp_camera_init(&config);
  if (err == ESP_OK) {
    if (sensor_t* sensor = esp_camera_sensor_get()) {
      sensor->set_hmirror(sensor, 0);
    }
  }
  i2c_driver_delete(I2C_NUM_1);
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

}  // namespace vision
