let
  myColors = import ./colors.nix;
in
{ config, pkgs, lib, ... }: {

  imports = [
    ./yubikey.nix
  ];

  home.username = "matthew";
  home.homeDirectory = "/home/matthew";

  home.packages = with pkgs; [
    ripgrep
    btop
    zip
    unzip
    fastfetch

    telegram-desktop
    gimp
    expressvpn

    jetbrains-mono
    noto-fonts
    noto-fonts-cjk-sans
    noto-fonts-color-emoji

    (pkgs.writeShellScriptBin "dmenu" ''
      exec ${pkgs.dmenu}/bin/dmenu \
        -i \
        -fn 'monospace-12' \
        -nb '#282c34' -nf '#abb2bf' -sb '#61afef' -sf '#282c34' \
        "$@"
    '')
  ];
  
  fonts.fontconfig.enable = true;
  
  home.stateVersion = "25.11";

  wayland.windowManager.sway = {
    enable = true;
    config = rec {
      startup = [
        { command = "${pkgs.mate.mate-polkit}/libexec/polkit-mate-authentication-agent-1"; }
      ];
      bars = [
        {
          statusCommand = "${pkgs.i3status}/bin/i3status";
          position = "top";
          
          colors = {
            background = myColors.dark;
            statusline = myColors.primary;
       
            focusedWorkspace = {
              background = myColors.offwhite;
              text = myColors.light;
              border = myColors.light;
            };
          };
        }
      ];

      window = {
        border = 2;
        titlebar = false;
      };
      input = {
        "type:keyboard" = {
          xkb_options = "caps:swapescape";
        };
      };
      gaps = {
        inner = 16;
        outer = 0;
      };
      # Define your color palette as variables for easy reuse
      colors = {
        background = myColors.offblack;
        focused = {
          border      = myColors.light;
          background  = myColors.light;
          text        = myColors.dark;
          indicator   = myColors.secondary;
          childBorder = myColors.light;
        };
        focusedInactive = {
          border      = myColors.offblack;
          background  = myColors.offblack;
          text        = myColors.light;
          indicator   = myColors.secondary;
          childBorder = myColors.offblack;
        };
        unfocused = {
          border      = myColors.offblack;
          background  = myColors.offblack;
          text        = myColors.light;
          indicator   = myColors.secondary;
          childBorder = myColors.offblack;
        };
        urgent = {
          border      = myColors.secondary;
          background  = myColors.secondary;
          text        = myColors.dark;
          indicator   = myColors.gray;
          childBorder = myColors.secondary;
        };
      };
      modifier = "Mod4";
      keybindings = lib.mkOptionDefault {
        "Mod4+Return" = "exec kitty";
      };
      output = {
        "Virtual-1" = {
          mode = "1920x1080@60Hz";
        };
      };
    };
  };

  programs.kitty = {
    enable = true;
    
    # Optional: Configure Kitty directly in Nix!
    settings = {
      font_family      = "JetBrains Mono";
      font_size        = "14.0";
      background_opacity = "1";

      cursor = myColors.light;
      foreground = myColors.light;
      background = myColors.offblack;
    };
    
    # Optional: Set a theme if you want
  };

  programs.vscode = {
    enable = true;
    package = pkgs.vscodium;
    profiles.default = {
      extensions = with pkgs.vscode-extensions; [
        jnoortheen.nix-ide
      ];
      # not working : 
      userSettings = {
        "nix.serverPath" = "nixd";
        "nix.enableLanguageServer" = true;
        "nixpkgs" = {
          "expr" ="import <nixpkgs> { }";
        };
        "formatting" = {
          "command" = [
            "nixfmt"
          ];
        };
        "nix.formatterPath" = "nixfmt";
        "git.autofetch" = true;
        "update.showReleaseNotes" = false;
      };
    };
  };

}
