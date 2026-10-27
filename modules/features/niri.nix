{ self, inputs, ... }: {
  flake.modules.nixos.niri = { pkgs, lib, config, ... }: {
    imports = [ self.modules.nixos.mouse ];

    programs.niri = {
      enable = true;
      # Built here rather than pulled from self.packages, so that the mouse
      # scaling can follow this host's my.mouse settings.
      package = self.lib.mkNiri {
        inherit pkgs lib;
        mouseAccelSpeed = config.my.mouse.accelSpeed;
      };
    };
  };

  # Keeps `nix build .#myNiri` working, at the unscaled default.
  perSystem = { pkgs, lib, ... }: {
    packages.myNiri = self.lib.mkNiri { inherit pkgs lib; };
  };

  flake.lib.mkNiri =
    { pkgs
    , lib
    , # libinput flat-profile scale for mice; 0.0 is 1:1 with the hardware.
      # See my.mouse in modules/features/mouse.nix.
      mouseAccelSpeed ? 0.0
    }:
    let
      noctalia = inputs.noctalia.packages.${pkgs.stdenv.hostPlatform.system}.default;

      # Mod+M, see the bind below.
      columnWidthToggle = pkgs.writeShellApplication {
        name = "niri-column-width-toggle";
        runtimeInputs = [ pkgs.jq pkgs.niri ];
        bashOptions = [ "nounset" "pipefail" ];
        text = builtins.readFile ./niri/column-width-toggle.sh;
      };
    in
    inputs.wrapper-modules.wrappers.niri.wrap {
      inherit pkgs;
      settings = {
        spawn-at-startup = [
          (lib.getExe noctalia)
        ];

        xwayland-satellite.path = lib.getExe pkgs.xwayland-satellite;

        input = {
          keyboard.xkb = {
            layout = "us";
            options = "caps:escape";
          };

          touchpad = {
            accel-speed = 0.0;
            accel-profile = "flat";

            tap = {};
            natural-scroll = {};
          };

          mouse = {
            # Normalise every mouse to my.mouse.targetDpi, so the same hand
            # movement covers the same distance on screen no matter what the
            # hardware DPI underneath is.
            accel-speed = mouseAccelSpeed;
            accel-profile = "flat";
          };

          # libinput sorts some pointers into their own classes, which would
          # otherwise fall back to the adaptive (accelerated) profile.
          trackball = {
            accel-speed = 0.0;
            accel-profile = "flat";
          };

          trackpoint = {
            accel-speed = 0.0;
            accel-profile = "flat";
          };
        };

        prefer-no-csd = {};
	      layout = {
          gaps = 8;

          # Half the 1920x1200 panel is a 948px column -- about 131 columns of
          # JetBrains Mono at 12pt, which Claude Code fills exactly, and it
          # still leaves room for a second window beside it. Two thirds read
          # as most of the screen in practice and crowded out whatever was
          # next to it, so kitty and the browser open at half.
          default-column-width = { proportion = 0.5; };

          # Mod+R cycles these, so resizing either way is one key away: from
          # the half-width default a press gives two thirds, then full width,
          # and another wraps round to a third.
          preset-column-widths = [
            { proportion = 0.33333; }
            { proportion = 0.5; }
            { proportion = 0.66667; }
            { proportion = 1.0; }
          ];
        };

        binds = {
          "Mod+Return".spawn-sh = "kitty";
          "Mod+B".spawn-sh = "chromium";
          # vscode moved off Mod+C to make room for voice below. Still bound
          # because it is still installed and configured (programs.vscode in
          # matthew-home.nix), just no longer a first-row key now that the
          # editing happens in Zed.
          "Mod+Shift+C".spawn-sh = "vscode";

          # Talk to Claude: press, speak, press again. C for Claude, which is
          # worth the better key -- vscode moved to Mod+Shift+C above.
          # `voice-ptt reset` starts a fresh conversation. See
          # modules/features/voice.nix for why it is a toggle rather than one
          # press (this laptop's microphone cannot be voice-detected by
          # amplitude).
          #
          # Resolved from PATH like kitty and chromium above rather than by
          # store path, because the command is installed through home-manager
          # (home.packages) and this file is the NixOS side -- naming a path
          # here would couple the compositor to one user's profile.
          "Mod+C".spawn-sh = "voice-ptt";

          # corkboard (modules/features/corkboard.nix), from PATH for the same
          # reason as voice-ptt. Shift opens it on the second brain VM, as the
          # "corkboard (brain-vm)" launcher entry does.
          "Mod+I".spawn-sh = "corkboard";
          "Mod+Shift+I".spawn-sh = "corkboard --host brain-vm";
          # The day plan, in its own window (corkboard.nix); again brings it
          # forward.
          "Mod+P".spawn-sh = "day-plan";

          "Mod+Q".close-window = {};
          "Mod+Space".spawn-sh = "${lib.getExe noctalia} msg panel-toggle launcher";
          # noctalia's region screenshot, with the screen-dim sheet out of the
          # frame (modules/features/adaptive-display.nix); from PATH like
          # voice-ptt.
          "Mod+S".spawn-sh = "screenshot-region";
          "Mod+Tab".toggle-overview = {};
          
          "Mod+F".fullscreen-window = {};
          # Half width <-> full width, rather than maximize-column's "full
          # width <-> whatever it was before".
          "Mod+M".spawn-sh = "${lib.getExe columnWidthToggle}";
          "Mod+R".switch-preset-column-width = {};

          "XF86AudioRaiseVolume".spawn-sh = "${lib.getExe noctalia} msg volume-up";
          "XF86AudioLowerVolume".spawn-sh = "${lib.getExe noctalia} msg volume-down";
          "XF86AudioMute".spawn-sh = "${lib.getExe noctalia} msg volume-mute";
          
          "XF86AudioMicMute".spawn-sh = "${lib.getExe noctalia} msg mic-mute";

          # screen-brightness rather than noctalia directly, and named rather
          # than given by store path like everything else here: it is built
          # from my.adaptiveDisplay options that mkNiri cannot see, and
          # threading them through would mean a second copy of the floor and
          # the step sizes to keep in step with the first. home.packages puts
          # it on /etc/profiles/per-user/matthew/bin, which is on the PATH
          # niri spawns with.
          #
          # What it adds is the stretch below the backlight's floor, where
          # this panel stops responding to logind at all and the overlay
          # takes over -- see modules/features/adaptive-display.nix. Above the
          # floor it hands back to noctalia's own step, so nothing about the
          # keys changes until the point where they used to stop working.
          "XF86MonBrightnessUp".spawn-sh = "screen-brightness up";
          "XF86MonBrightnessDown".spawn-sh = "screen-brightness down";

          # Force the night light's warm end on, regardless of the hour. With
          # no ambient light sensor on this machine the schedule is working
          # from the sun's position alone, so it has no way to know about a
          # dark room at noon -- this is the manual override for that.
          "Mod+N".spawn-sh = "${lib.getExe noctalia} msg nightlight-force-toggle";

          # Media Controls
          "XF86AudioPlay".spawn-sh = "${lib.getExe noctalia} msg media toggle";
          "XF86AudioStop".spawn-sh = "${lib.getExe noctalia} msg media stop";
          "XF86AudioPrev".spawn-sh = "${lib.getExe noctalia} msg media previous";
          "XF86AudioNext".spawn-sh = "${lib.getExe noctalia} msg media next";

          "Mod+Shift+H".move-column-left = {};
          "Mod+Shift+J".move-window-down = {};
          "Mod+Shift+K".move-window-up = {};
          "Mod+Shift+L".move-column-right = {};
          "Mod+H".focus-column-left = {};
          "Mod+J".focus-window-down = {};
          "Mod+K".focus-window-up = {};
          "Mod+L".focus-column-right = {};

          "Mod+1".focus-workspace = 1;
          "Mod+2".focus-workspace = 2;
          "Mod+3".focus-workspace = 3;
          "Mod+4".focus-workspace = 4;
          "Mod+5".focus-workspace = 5;
          "Mod+6".focus-workspace = 6;
          "Mod+7".focus-workspace = 7;
          "Mod+8".focus-workspace = 8;
          "Mod+9".focus-workspace = 9;
          "Mod+0".focus-workspace = 10;

          "Mod+Shift+1".move-column-to-workspace = 1;
          "Mod+Shift+2".move-column-to-workspace = 2;
          "Mod+Shift+3".move-column-to-workspace = 3;
          "Mod+Shift+4".move-column-to-workspace = 4;
          "Mod+Shift+5".move-column-to-workspace = 5;
          "Mod+Shift+6".move-column-to-workspace = 6;
          "Mod+Shift+7".move-column-to-workspace = 7;
          "Mod+Shift+8".move-column-to-workspace = 8;
          "Mod+Shift+9".move-column-to-workspace = 9;
          "Mod+Shift+0".move-column-to-workspace = 10;
        };
      };
    };
}
