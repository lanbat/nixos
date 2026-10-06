# modules/core/voice-satellite-diagnostics.nix
#
# `voice-satellite-diagnostics`: one command that says whether this host's
# voice satellite is healthy: its services, Home Assistant's connection to it,
# the Snapcast client, the audio devices and streams, the microphone's level
# over a few seconds, CPU, memory, temperature, power and recent errors.
#
# The audio sections talk to the system-wide PipeWire, which needs the
# pipewire group or root: run it with sudo.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.lanbat.voiceSatellite;
  lva = cfg.backend == "lva";
  usesPipewire = config.services.pipewire.enable or false;

  unit = if lva then "linux-voice-assistant" else "wyoming-satellite";
  port = if lva then cfg.lva.port else lib.toInt (lib.last (lib.splitString ":" cfg.uri));

  # What the satellite records from, as PipeWire names it (modules/pi/audio.nix).
  captureNode =
    if lva && cfg.echoCancellation.enable then
      cfg.echoCancellation.pulseSourceName
    else if lva && cfg.lva.audioInputDevice != null then
      cfg.lva.audioInputDevice
    else
      "lanbat_ps_eye_capture";

  units = lib.escapeShellArgs (
    [ unit ]
    ++ lib.optional (config.systemd.services ? lva-snapcast-duck) "lva-snapcast-duck"
    ++ lib.optional (config.systemd.services ? snapclient) "snapclient"
    ++ lib.optionals usesPipewire [
      "pipewire"
      "pipewire-pulse"
      "wireplumber"
    ]
  );

  diagnostics = pkgs.writeShellApplication {
    name = "voice-satellite-diagnostics";
    runtimeInputs = with pkgs; [
      coreutils
      gawk
      gnugrep
      iproute2
      procps
      sox
      systemd
      alsa-utils
      usbutils
      config.services.pipewire.package
      config.services.pipewire.wireplumber.package
    ];
    text = ''
      export PIPEWIRE_RUNTIME_DIR=/run/pipewire
      units=(${units})
      section() { printf '\n== %s\n' "$1"; }
      ok() { printf '  ok    %s\n' "$1"; }
      bad() { printf '  FAIL  %s\n' "$1"; }
      warn() { printf '  warn  %s\n' "$1"; }

      echo "Voice satellite ${lib.escapeShellArg cfg.name} on $(hostname): backend ${cfg.backend}, port ${toString port}"

      section "Services"
      for u in "''${units[@]}"; do
        state=$(systemctl is-active "$u" || true)
        restarts=$(systemctl show -p NRestarts --value "$u")
        since=$(systemctl show -p ActiveEnterTimestamp --value "$u")
        if [ "$state" = active ]; then ok "$u (since $since, $restarts restarts)"; else bad "$u is $state"; fi
      done

      ${lib.optionalString (lva && usesPipewire) ''
        # LVA running without its recording stream hears nothing and logs nothing.
        if systemctl is-active -q ${unit} && wpctl status >/dev/null 2>&1; then
          if pw-cli ls Node 2>/dev/null | grep -q 'node.name = "linux-voice-assistant"'; then
            ok "${unit} is recording"
          else
            bad "${unit} has no recording stream: the satellite is deaf (restart it)"
          fi
        fi
      ''}
      section "Home Assistant"
      peers=$(ss -Htn state established "( sport = :${toString port} )" | awk '{print $4}' | sort -u)
      if [ -n "$peers" ]; then ok "connected from $(echo "$peers" | tr '\n' ' ')"; else bad "no connection on port ${toString port}: Home Assistant has not connected"; fi
      ${lib.optionalString lva ''
        echo "  wake words: ${lib.concatStringsSep ", " cfg.lva.wakeModels}, stop word: ${cfg.lva.stopWord.model}"
        last=$(journalctl -u ${unit} -n 200 --no-pager -o cat 2>/dev/null | grep -iE "wake word|connected|disconnect" | tail -3 || true)
        [ -n "$last" ] && printf '  log: %s\n' "''${last//$'\n'/$'\n'  log: }"
      ''}

      ${lib.optionalString (config.systemd.services ? snapclient) ''
        section "Snapcast"
        server=$(systemctl show -p ExecStart --value snapclient | grep -o -- '--host [^ ]*' | awk '{print $2}' || true)
        if [ -n "$server" ] && timeout 3 bash -c "exec 3<>/dev/tcp/$server/1704" 2>/dev/null; then
          ok "snapserver $server:1704 reachable"
        else
          bad "snapserver ''${server:-?}:1704 unreachable"
        fi
        if ss -Htnp state established "( dport = :1704 )" 2>/dev/null | grep -q .; then ok "snapclient streaming connection open"; else warn "no established connection to port 1704 (seen as root only)"; fi
      ''}

      section "Audio devices"
      grep -E '^ *[0-9]+ \[' /proc/asound/cards | sed 's/^/  /' || warn "no sound cards"
      lsusb | grep -viE "hub|ethernet" | sed 's/^/  usb: /' || true
      ${lib.optionalString usesPipewire ''
        if ! wpctl status >/dev/null 2>&1; then
          warn "cannot reach PipeWire: run with sudo (or as a member of the pipewire group)"
        else
          wpctl status 2>/dev/null | sed -n '/^Audio/,/^Video/p' | grep -vE '^Video|^ *$' | sed 's/^/  /'
          section "Streams and rates"
          pw-cli ls Node 2>/dev/null | awk -F'"' '/node.name/{n=$2} /media.class/{print "  " n "  (" $2 ")"}'
          pw-top -b -n 2 2>/dev/null | tail -n +2 | awk 'NR>1 && $0 !~ /^S/' | sed 's/^/  /' | head -20 || true

          seconds="''${1:-3}"
          section "Microphone (${captureNode}, ''${seconds}s)"
          dir=$(mktemp -d); trap 'rm -rf "$dir"' EXIT
          timeout "$seconds" pw-record --target ${captureNode} --rate 16000 --channels 1 "$dir/mic.wav" 2>/dev/null || true
          if [ -s "$dir/mic.wav" ] && stats=$(sox "$dir/mic.wav" -n stats 2>&1); then
            peak=$(echo "$stats" | awk '/Pk lev dB/{print $4}')
            rms=$(echo "$stats" | awk '/RMS lev dB/{print $4}')
            echo "  peak ''${peak} dBFS, RMS ''${rms} dBFS (speech near the mic should peak above about -20)"
            awk -v r="$rms" 'BEGIN{exit !(r+0 < -70)}' && bad "practically silent: is the microphone muted or the wrong device?"
          else
            bad "could not record from ${captureNode}"
          fi
        fi
      ''}

      section "System"
      read -r l1 l5 l15 _ < /proc/loadavg
      echo "  load $l1 $l5 $l15 on $(nproc) cores"
      top -bn2 -d1 | awk '/^%Cpu/{c=$0} END{print "  cpu:" substr(c, index(c, ":")+1)}'
      ps -eo pid,user,pcpu,rss,comm --sort=-pcpu | head -6 | sed 's/^/  /' || true
      free -m | awk 'NR==2{printf "  memory: %s MB used of %s, %s available\n", $3, $2, $7} NR==3{printf "  swap: %s MB used\n", $3}'
      for z in /sys/class/thermal/thermal_zone*/temp; do
        [ -r "$z" ] && awk '{printf "  temperature: %.1f C\n", $1/1000}' "$z"
      done
      for a in /sys/class/hwmon/hwmon*/in0_lcrit_alarm; do
        if [ -r "$a" ]; then
          if [ "$(cat "$a")" = 1 ]; then bad "undervoltage: the power supply is too weak"; else ok "supply voltage"; fi
        fi
      done
      df -h / | awk 'NR==2{printf "  disk: %s used of %s\n", $3, $2}'
      echo "  journal: $(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[KMG]' | head -1)"

      section "Recent warnings and errors (last hour)"
      args=()
      for u in "''${units[@]}"; do args+=(-u "$u"); done
      journalctl "''${args[@]}" -p warning --since -1h --no-pager -o short -n 15 2>/dev/null | grep -v -- '-- No entries --' | sed 's/^/  /' || echo "  none"
      journalctl -k -p warning --since -1h --no-pager -o short -n 5 2>/dev/null | grep -v -- '-- No entries --' | sed 's/^/  kernel: /' || true
    '';
  };
in
{
  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ diagnostics ];
  };
}
