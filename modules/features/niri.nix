{ self, inputs, ... }: {
  flake.nixosModules.niri = { pkgs, lib, ... }: {
    programs.niri = {
      enable = true;
      package = self.packages.${pkgs.stdenv.hostPlatform.system}.myNiri;
    };
  };

  perSystem = { pkgs, lib, self', inputs', ... }: {
    packages.myNiri = inputs.wrapper-modules.wrappers.niri.wrap {
      inherit pkgs;
      settings = {
        spawn-at-startup = [
          (lib.getExe inputs'.noctalia.packages.default)
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
        };

        layout.gaps = 8;

        binds = {
          "Mod+Return".spawn-sh = "kitty";
          "Mod+B".spawn-sh = "chromium";
          "Mod+C".spawn-sh = "vscode";

          "Mod+Q".close-window = {};
          "Mod+Space".spawn-sh = "${lib.getExe inputs'.noctalia.packages.default} msg panel-toggle launcher";
          "Mod+S".spawn-sh = "${lib.getExe inputs'.noctalia.packages.default} msg screenshot-region";
          "Mod+Tab".toggle-overview = {};
          
          "Mod+F".fullscreen-window = {};
          "Mod+M".maximize-column = {};

          "XF86AudioRaiseVolume".spawn-sh = "${lib.getExe inputs'.noctalia.packages.default} msg volume-up";
          "XF86AudioLowerVolume".spawn-sh = "${lib.getExe inputs'.noctalia.packages.default} msg volume-down";
          "XF86AudioMute".spawn-sh = "${lib.getExe inputs'.noctalia.packages.default} msg volume-mute";
          
          "XF86AudioMicMute".spawn-sh = "${lib.getExe inputs'.noctalia.packages.default} msg mic-mute";

          "XF86MonBrightnessUp".spawn-sh = "${lib.getExe inputs'.noctalia.packages.default} msg brightness-up";
          "XF86MonBrightnessDown".spawn-sh = "${lib.getExe inputs'.noctalia.packages.default} msg brightness-down";

          # Media Controls
          "XF86AudioPlay".spawn-sh = "${lib.getExe inputs'.noctalia.packages.default} msg media toggle";
          "XF86AudioStop".spawn-sh = "${lib.getExe inputs'.noctalia.packages.default} msg media stop";
          "XF86AudioPrev".spawn-sh = "${lib.getExe inputs'.noctalia.packages.default} msg media previous";
          "XF86AudioNext".spawn-sh = "${lib.getExe inputs'.noctalia.packages.default} msg media next";

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
  };
}
