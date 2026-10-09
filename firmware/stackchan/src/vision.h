// Faces seen through the CoreS3's camera, detected on the robot (esp-dl).
// Nothing but a face's position leaves this file: no picture is stored or sent.
#pragma once

#include <Arduino.h>

struct Sighting {
  bool face = false;    // a face in the latest frame
  float x = 0;          // its centre, -1 (robot's left) .. 1 (robot's right)
  float y = 0;          // -1 (down) .. 1 (up)
  float size = 0;       // box width as a share of the frame
  uint32_t at = 0;      // millis() of the frame
};

namespace vision {

// Starts the camera and the detector on core 0. False when there is no
// camera: the robot works without one, it just doesn't look at people.
bool begin();

// The latest sighting (copied under a lock).
Sighting latest();

// Paused while asleep: no frames, less heat and power.
void setPaused(bool paused);

}  // namespace vision
