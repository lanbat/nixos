# Raspberry Pi 3 as a Snapcast speaker and voice satellite

A Pi 3 (B or B+) with a speaker and a USB microphone. It plays the Snapcast stream
(`modules/pi/snapclient.nix`) and is a Wyoming satellite for Home Assistant's Assist
(`lanbatPlugins.voice`). It uses the `voice-pi` role and `platform = "raspberry-pi-3"`
(`hosts/pi3/hardware.nix`): the stock NixOS aarch64 SD image, with U-Boot and the
mainline kernel from cache.nixos.org. The Pi 5 images from nixos-raspberrypi are not
used.

## Requirements

- **Raspberry Pi 3 B or B+**, 1 GB of RAM, wired Ethernet.
- **microSD card, 32 GB recommended (the size this setup was built and tested on).** It
  holds the whole system, since the Pi has no other storage. The root filesystem grows to
  fill the card on first boot. After the configuration was switched in and several
  generations had accumulated, about 8 GB was in use (the Nix store with the voice
  satellite, PipeWire, Bluetooth and the old generations; the capped journal adds up to
  64 MB), so 16 GB is the practical floor, and a smaller card leaves no room for
  generations and rollbacks. Use a quality card (A1/A2, a known brand): the system and
  the journal write to it all the time.
- **A 5 V / 2.5 A power supply** with a short, thick cable. A weak one makes the Pi log
  `Undervoltage detected!` and crash at random; `cat /sys/class/hwmon/hwmon*/in0_lcrit_alarm`
  reads 1 while the supply is too weak.
- **A USB microphone.** The PlayStation Eye (USB 1415:2000) is the default; its speech is
  quiet, so the deploy entry sets `lanbat.voiceSatellite.microphone.volumeMultiplier`.
- **A speaker**: the 3.5 mm jack, a USB speaker or a Bluetooth speaker (section 5).

## Deploy entry

```nix
pi-voice = {
  role = "voice-pi";
  system = "aarch64-linux";
  platform = "raspberry-pi-3";
  networking = {
    ip = "192.0.2.12";
    interface = "eth0"; # pinned by hosts/pi3/hardware.nix
    hostname = "pi3";
  };
  plugins = [ inputs.self.lanbatPlugins.voice ];
  modules = [
    {
      lanbat.voiceSatellite.name = "Pi 3 Satellite"; # what Home Assistant calls it
      # lanbat.speakers.output = "usb";   # "analog", "usb", "bluetooth" or "auto"
      # lanbat.speakers.bluetooth.address = "AA:BB:CC:DD:EE:FF";
    }
  ];
};
```

The `voice-pi` role bundles the Snapcast client (`snapclient`) and the speaker choice
(`speakers`); `roleModules.snapclient = null` drops the client for a satellite that
should not play the stream. `deployments/example/deploy.nix` has the same host, which CI
evaluates.

The server's firewall admits the Pi for Snapcast and InfluxDB, and the Pi admits only the
server on the satellite's port 10700, all generated from the declared services.

## 1. Flash the card

The official image is `nixos-image-sd-card-<version>-aarch64-linux.img.zst`. **This erases
the card**; check the device with `lsblk`.

```bash
zstd -dc nixos-image-sd-card-*-aarch64-linux.img.zst | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
```

Then, on the card:

- mount the `NIXOS_SD` partition and put your key in `root/.ssh/authorized_keys` (mode 0600,
  directory 0700), so root can log in on first boot;
- mount the `FIRMWARE` partition and add `dtparam=audio=on` to the end of `config.txt`, which
  switches on the 3.5 mm jack.

The image grows its root partition to fill the card on first boot.

## 2. First boot

Connect Ethernet and power. The Pi takes a DHCP address; find it in the router, or with
`ping nixos.local`.

```bash
ssh root@<pi-ip>
lsusb                  # the microphone should be listed (PlayStation Eye is 1415:2000)
ssh-keyscan -t ed25519 <pi-ip>   # the Pi's host key, for the next step
```

## 3. Add the Pi's host key to the secrets

Add the key to `secrets/secrets.nix` as `pi-voice`, add it to `allKeys` (this Pi reads
`telegraf-token.age`), and re-encrypt:

```bash
(cd secrets && agenix -r)
```

If the Pi has a room in `lanbat.voiceRooms` it also reads `ha-voice-token.age`. With no
room, replies play on the Pi's own speaker (`alwaysPlayLocally`) and no token is needed.

## 4. Switch to the configuration

Build on the Pi (nothing here emulates aarch64); nearly everything comes from
cache.nixos.org. Use `boot` rather than `switch`, because the address changes from DHCP to
the static one in the middle of the session:

```bash
nix run nixpkgs#nixos-rebuild -- boot --flake path:.#homelab-pi-voice \
  --target-host root@<pi-ip> --build-host root@<pi-ip>
ssh root@<pi-ip> reboot
```

After the reboot, log in as `admin` on the static address. From then on:
`deploy --skip-checks path:.#homelab-pi-voice`.

## 5. Speakers

PipeWire plays to its default output, and `lanbat.speakers.output` raises one kind above the
others. Check what the Pi sees:

```bash
wpctl status           # needs the pipewire group; the default output has a *
aplay -l               # the analog jack is "Headphones", a USB speaker "USB Audio"
```

- **Analog**: plug in the jack. No setup.
- **USB**: plug it in. No setup.
- **Bluetooth**: pair once by hand, then set `lanbat.speakers.bluetooth.address` so the Pi
  reconnects whenever the speaker is switched off and on.

  ```bash
  bluetoothctl
  > scan on
  > pair AA:BB:CC:DD:EE:FF
  > trust AA:BB:CC:DD:EE:FF
  > connect AA:BB:CC:DD:EE:FF
  ```

  Bluetooth through a system-wide PipeWire is the least tested path. If the speaker pairs
  but no `bluez_output` node appears in `wpctl status`, use the analog or USB output.

  The Pi 3's onboard Bluetooth chip is unreliable under the mainline kernel: the kernel log
  fills with `Frame reassembly failed` and `unknown connection handle`, the Pi reports the
  speaker as connected while the speaker has dropped the pairing, and it is sensitive to an
  under-spec power supply. Prefer the analog or USB output, or add a USB Bluetooth adapter.

  Whichever output is used, the wake chime is padded with silence on purpose: the satellite
  mutes its microphone for the length of the chime file, and a chime the microphone still
  hears makes the assistant end the command before you speak ("No text recognized").

## 6. Home Assistant

`home-assistant-post-setup` registers the Wyoming satellite of every `voice-pi` host, so
deploying the server after this host exists adds it (as `satellite-pi-voice`) with no UI
step. Give the device an area, and check **Settings → Voice assistants** has the **Voice**
pipeline selected for it. Saying "hey nabu" does nothing until the server has been
deployed with this host in the deployment; `ss -tn | grep 10700` on the Pi shows an
established connection once Home Assistant has it.

`home-assistant-post-setup` sets each satellite's **Finished speaking detection** to
**Aggressive** once, so a satellite added afterwards keeps Home Assistant's default,
**Relaxed**, which waits over a second after a command. On the new device, set it to
**Aggressive** too.

The conversation agent runs on the server (`lanbat.deployment.haLlm`, see
`services/llama-cpp.nix`), and so do speech-to-text and Piper. The Pi 3 only streams the
microphone and plays the audio it is sent, so its 1 GB of RAM and slow CPU are not in the
path of how fast it answers.
