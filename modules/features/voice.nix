# Talking to Claude out loud: Mod+V, speak, hear the answer.
#
# Three local pieces around one remote one. whisper.cpp turns the microphone
# into text, `claude -p` answers on the subscription already logged in under
# ~/.claude, and piper reads the answer back through the speakers. Only the
# middle step leaves the machine.
#
# Measured on omni-laptop, which is what settled the design:
#
#   whisper base.en, 3s clip, 12 threads   1.0-1.2 s
#   claude -p (Sonnet 5)                   6.2 s
#   piper, 6s of speech                    1.3 s
#
# So the round trip is ~8.5s and Claude is 73% of it. That is the reason this
# does not use the NPU. The hardware is real -- XDNA2 at 1022:17f0, amdxdna
# loaded, /dev/accel/accel0 present -- but nixpkgs has no XRT, no xdna-driver
# userspace and no VitisAI execution provider for onnxruntime, and whisper.cpp
# has no XDNA backend upstream at all. Packaging AMD's stack and quantizing
# models for it would be a project, and the prize is 2.3 seconds of an 8.5
# second loop. If the 1.0s ever does matter, `whisper-cpp` takes
# `vulkanSupport = true` as a plain override and this laptop has a Radeon iGPU
# -- that is the cheap win, not the NPU.
#
# Why a compositor keybind and not a Zed extension: Zed extensions are WASM
# (wasm32-wasip2) and the API exposes environment variables and PATH lookups,
# nothing else -- no audio, no microphone, no devices. Its one native
# extension type is an MCP server, and those are only ever invoked by the
# agent, so the loop would have to be started by typing. A key you can press
# without looking is the entire point, so the script drives and the editor is
# not involved.
{ ... }:
{
  flake.modules.homeManager.voice = { pkgs, lib, config, ... }:
    let
      cfg = config.my.voice;

      # Pinned rather than fetched at runtime by whisper-cpp's own downloader,
      # so the models are content-addressed like everything else and a fresh
      # machine does not depend on huggingface being up at first use.
      whisperModel = pkgs.fetchurl {
        name = "ggml-base.en.bin";
        url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin";
        hash = "sha256-oDd5yG3zMjB19eeWyyzlAp8A7Ihp7uP9+4l6/jbG0AI=";
      };

      # piper insists on finding the config beside the weights and named for
      # them, so the pair is assembled into one directory rather than passed as
      # two paths.
      piperVoice = pkgs.runCommand "piper-voice-en_US-amy-medium" { } ''
        mkdir -p "$out"
        cp ${pkgs.fetchurl {
          name = "en_US-amy-medium.onnx";
          url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/amy/medium/en_US-amy-medium.onnx";
          hash = "sha256-s6bke1e4x/vmoM4lGBYaUPWanN2KUINcAssCvdYgbBg=";
        }} "$out/en_US-amy-medium.onnx"
        cp ${pkgs.fetchurl {
          name = "en_US-amy-medium.onnx.json";
          url = "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/amy/medium/en_US-amy-medium.onnx.json";
          hash = "sha256-laI+tNQpCdON9zu5rH9F9Zfb/N4tG/lSb96vVGaXfXc=";
        }} "$out/en_US-amy-medium.onnx.json"
      '';

      # Pressing a key and then wondering whether anything is listening is the
      # failure that makes a feature like this go unused, so there is a sound
      # as well as a notification -- the notification is on a screen that may
      # not be the one being looked at.
      beep = pkgs.runCommand "voice-beep.wav" { nativeBuildInputs = [ pkgs.sox ]; } ''
        sox -n -r 22050 -c 1 -b 16 "$out" synth 0.08 sine 880 fade q 0.01 0.08 0.03 vol 0.25
      '';

      voicePtt = pkgs.writeShellApplication {
        name = "voice-ptt";
        runtimeInputs = [
          pkgs.sox                 # mic capture plus the silence-triggered auto-stop
          pkgs.whisper-cpp         # whisper-cli
          pkgs.piper-tts           # piper
          pkgs.pulseaudio          # paplay, which pipewire-pulse answers
          pkgs.libnotify
          pkgs.jq
          pkgs.util-linux          # flock
          pkgs.coreutils
          pkgs.gnused
        ];
        # No errexit: a missing notification daemon, a beep that will not play
        # or a transcript that comes back empty are all ordinary outcomes of
        # pressing this key, and none of them should abort the exchange.
        bashOptions = [ "nounset" "pipefail" ];
        text = builtins.replaceStrings
          [ "@model@" "@voice@" "@beep@" "@model_name@" "@threads@" "@maxSeconds@" ]
          [
            "${whisperModel}"
            "${piperVoice}/en_US-amy-medium.onnx"
            "${beep}"
            cfg.model
            (toString cfg.threads)
            (toString cfg.maxSeconds)
          ]
          (builtins.readFile ./voice/voice-ptt.sh);
      };
    in
    {
      options.my.voice = {
        model = lib.mkOption {
          type = lib.types.str;
          default = "claude-opus-5";
          description = ''
            Which model answers. This is the whole latency budget -- 6.2s of an
            8.5s round trip, measured on Sonnet 5 -- so it is the one knob
            worth turning if the pauses grate. `claude-sonnet-5` is the
            step down, `claude-haiku-4-5` the one below that.

            Billed against the Claude subscription in ~/.claude rather than
            per token, so this is a latency choice and not a cost one.
          '';
        };

        threads = lib.mkOption {
          type = lib.types.ints.positive;
          default = 8;
          description = ''
            Threads for whisper. Measured at 345% CPU across 12 cores, so this
            is well short of saturating the machine on purpose: the press
            usually happens while something else is running.
          '';
        };

        maxSeconds = lib.mkOption {
          type = lib.types.ints.positive;
          default = 120;
          description = ''
            Hard cap on one recording. Recording ends on the second press, so
            this is only the backstop for a key pressed by accident and
            forgotten about -- generous on purpose, because cutting someone off
            mid-thought is the worse failure.
          '';
        };
      };

      config = {
        # On PATH as well as on the keybind: running it in a terminal shows
        # each stage, which is the whole story when a press does nothing.
        home.packages = [ voicePtt ];
      };
    };
}
