# Stack-chan: a face for the voice satellite

M5Stack's [StackChan](https://docs.m5stack.com/en/StackChan) kit is a small robot: a
CoreS3 (ESP32-S3) head with a touch screen, a camera and a head-touch sensor, two
feedback servos that turn and tilt it, and twelve RGB LEDs in its body. Plugged into a
voice satellite's USB port, it becomes the satellite's face. The Pi keeps the voice
(wake word, microphone, speaker), and the robot shows what the assistant is doing:

- **It notices people.** Its camera finds faces on the robot itself. It turns to whoever
  is in front of it and follows them. When someone appears after nobody was around, it
  glances over, nods and glows warm. With nobody there it looks around now and then, and
  after five minutes it dozes off until someone comes.
- **A conversation shows on it.** On the wake word it looks at you with cyan LEDs. While
  Home Assistant works it looks up, thinking, with violet LEDs going round. The reply
  shows as a caption, its mouth moves with the spoken reply, and its face matches the
  reply: happy, sad ("Sorry, I couldn't…"), or curious with a head tilt for a question.
  An error gets a head shake and a red flash.
- **Touch.** Tap its head to talk, with no wake word; tap again to stop. Stroking it from
  front to back just makes it happy. Any touch silences a ringing timer.
- **Timers.** The soonest timer counts down under its face, and the LEDs drain as it
  runs. When it rings, the robot wiggles and flashes amber.
- **Night.** From 23:00 to 07:00 it sleeps, dimmed, still and with its camera off. The
  wake word or a tap wakes it for the conversation.
- **Status.** One dim red LED on each side means the microphone is muted. A slow red
  pulse means Home Assistant is unreachable. "No Pi" means the bridge has stopped
  talking to it.

Nothing leaves the host. Frames are analysed on the robot and dropped; only a face's
position is used, to move the head. The bridge on the Pi reaches LVA on the loopback and
the robot over USB.

## Requirements

- The **StackChan kit** (CoreS3 with the servo body).
- A **voice satellite on the Linux Voice Assistant backend**
  (`lanbat.voiceSatellite.backend = "lva"`; see
  [pi3-satellite.md](pi3-satellite.md#6-voice-backends-wyoming-vs-linux-voice-assistant)).
  Evaluation fails, naming this setting, on the Wyoming backend.
- A **USB-C data cable** from the robot to the Pi. It powers the robot too. A Pi 3's
  1.2 A USB budget can run the servos, but on a weak supply the Pi reports undervoltage
  (`dmesg | grep -i voltage`). In that case use a powered hub, or let the robot's battery
  carry the peaks.

## 1. Flash the firmware

The robot runs `firmware/stackchan` (Arduino and PlatformIO, on top of M5Stack's
[StackChan-BSP](https://github.com/m5stack/StackChan-BSP)) in place of its stock
firmware. Build and flash it from any Linux machine with Nix, or from the Pi itself.

1. **Back up the stock firmware** first, so you can go back:
   ```bash
   nix shell nixpkgs#esptool -c esptool.py --chip esp32s3 -p /dev/ttyACM0 \
     read_flash 0 0x1000000 stackchan-stock.bin
   ```
2. **Build and upload:**
   ```bash
   cd firmware/stackchan
   nix shell nixpkgs#platformio -c pio run -t upload --upload-port /dev/ttyACM0
   ```
   The first build downloads the ESP32 toolchain to `~/.platformio` (about 1 GB). If
   the upload can't connect, hold the button on the CoreS3's side for about three
   seconds until its LED turns green (download mode), then upload again.
3. **Press the power button** afterwards. The robot stays off after the reset at the end
   of an upload.

To flash from the Pi, build on another machine and copy
`.pio/build/stackchan/{bootloader,partitions,firmware}.bin` and `boot_app0.bin` over.
Then write them with `esptool.py` at the addresses `pio run -t upload -v` prints.

To restore the stock firmware:
`esptool.py --chip esp32s3 -p /dev/ttyACM0 write_flash 0 stackchan-stock.bin`.

## 2. Enable the plugin

Add the plugin next to the voice plugin in the satellite's deploy entry:

```nix
pi-voice = {
  role = "voice-pi";
  platform = "raspberry-pi-3";
  # ...
  plugins = [
    inputs.self.lanbatPlugins.voice
    inputs.self.lanbatPlugins.stackchan
  ];
  modules = [
    {
      lanbat.voiceSatellite.backend = "lva";
      # Everything below is optional; these are the defaults.
      lanbat.stackchan = {
        # usbSerial = "...";        # pin one robot when another ESP32-S3 is plugged in
        captions = true;
        touchToTalk = true;
        noticeGuests = true;
        nightHours = { start = "23:00"; end = "07:00"; };   # null keeps it awake
        brightness = 180;
        nightBrightness = 10;
        # sadWords = [ "sorry" "leider" ];  # replies in another language
      };
    }
  ];
};
```

Deploy, and plug the robot in. udev links it as `/dev/stackchan`, and the
`lva-stackchan` unit (`pkgs/lva-stackchan`) connects to it and to LVA's peripheral API.
The robot can be plugged in and out at any time.

## 3. Check it

- `journalctl -u lva-stackchan -f` shows `robot connected on /dev/stackchan`,
  `robot firmware 1.0.0, protocol 1` and `following ws://127.0.0.1:6055`.
- `voice-satellite-diagnostics` lists the unit with the rest of the satellite.
- Say the wake word, then "set a timer for one minute": cyan, then violet, then the
  caption with a moving mouth. The countdown appears under the face, and a tap on its
  head silences the ring.
- Walk out of view for a minute and come back: it should turn to you and nod.

## How it fits together

```
 LVA ──ws://127.0.0.1:6055──▶ lva-stackchan (Pi) ──USB serial, JSON lines──▶ robot firmware
  ▲         events: wake, stt_text,     │  decides mood, captions, timers,      │ face, LEDs, head,
  │         thinking, tts_*, timer_*,   │  night; mouth from the speaker's      │ camera tracking,
  └──── start_listening, stop_pipeline, │  PipeWire monitor while a reply plays │ touch
        stop_timer_ringing ◀────────────┘                              ◀── touch, face seen
```

The robot does everything that has to be quick or smooth by itself: drawing the face,
blinking, following a face, gestures, LED animation. If the Pi goes away, it still
behaves like a pet. The bridge holds the decisions in one class with no I/O (`Brain`),
which `nix build .#checks.x86_64-linux.stackchan-bridge` drives with scripted
conversations.

### Serial protocol (version 1)

One JSON object per line, 115200 baud over the CoreS3's USB port.

| Pi → robot | Meaning |
|---|---|
| `{"mood": "neutral\|listening\|thinking\|happy\|sad\|surprised\|sleepy\|confused\|curious"}` | Face and LED scene |
| `{"look": "track\|user\|up\|center"}` | Follow faces, look at the speaker, look up (thinking), straight ahead |
| `{"gesture": "perk\|nod\|shake\|wiggle\|tilt"}` | A short head movement |
| `{"mouth": 0.0–1.0}` | Mouth opening, about 20 times a second while a reply plays |
| `{"caption": {"text", "who", "ms"}}` | Caption under the face for `ms` |
| `{"timers": [{"id", "name", "remaining_s", "total_s", "ringing"}]}` | All timers, soonest first |
| `{"sleep": bool}` | Night: dim, still, camera off |
| `{"status": {"muted", "online"}}` | Muted microphone; Home Assistant reachable |
| `{"config": {"brightness", "notice"}}` | Screen brightness; whether to greet newcomers |
| `{"ping": 1}` | Heartbeat every 3 s. After 10 s without any line the robot shows "No Pi" |

| Robot → Pi | Meaning |
|---|---|
| `{"hello": {"fw", "proto"}}` | At boot and when the Pi comes back; the bridge answers with the whole state |
| `{"touch": "tap\|stroke", "zone": "front\|middle\|back\|screen"}` | Head tap or stroke, or a tap on the face |
| `{"face": "new\|lost"}` | Someone came into view, or left it |
| `{"log": "..."}` | Shown in the bridge's journal |

## Troubleshooting

- **No `/dev/stackchan`.** Check `udevadm info /dev/ttyACM0 | grep -E 'ID_VENDOR_ID|ID_MODEL_ID'`
  for `303a`/`1001`. The stock firmware (or a board in download mode) may enumerate
  differently: flash the firmware first.
- **The bridge warns about the protocol.** The robot runs older firmware than the bridge
  expects. Flash `firmware/stackchan` from the same commit as the Pi's configuration.
- **It never looks at anyone.** The robot logs `no camera: not looking at people` when
  the camera didn't start; everything else still works. Power-cycle it with the button.
- **The mouth doesn't move.** The bridge records the default speaker's monitor through
  PipeWire. `journalctl -u lva-stackchan` shows `pw-record` errors, and
  `pw-cli ls Node | grep lva-stackchan-mouth` shows the stream while a reply plays.
- **The head jitters or a servo is limp.** The servos lose torque when they rest, to
  stay quiet and cool, and come back on the next move. A limp servo that never moves
  again points at power: check the cable and `dmesg` for undervoltage.
