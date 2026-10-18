{ self, inputs, ... }: {
  flake.nixosModules.niri = { pkgs, lib, config, ... }: {
    imports = [ self.nixosModules.mouse ];

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
          "Mod+C".spawn-sh = "vscode";

          "Mod+Q".close-window = {};
          "Mod+Space".spawn-sh = "${lib.getExe noctalia} msg panel-toggle launcher";
          "Mod+S".spawn-sh = "${lib.getExe noctalia} msg screenshot-region";
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

          "XF86MonBrightnessUp".spawn-sh = "${lib.getExe noctalia} msg brightness-up";
          "XF86MonBrightnessDown".spawn-sh = "${lib.getExe noctalia} msg brightness-down";

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
