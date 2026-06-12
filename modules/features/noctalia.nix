# modules/features/noctalia.nix
{ inputs, lib, ... }:

let 
  baseSettings = builtins.fromTOML (builtins.readFile ./noctalia-config.toml);
in
{
  # Every file in the dendritic pattern is strictly a top-level flake-parts module.
  # We use flake.modules.<class>.<feature> to house our config.
  
  config.flake.modules.homeManager.noctalia = { config, ... }: {

    # 1. IMPORT the external home-manager module exactly here
    imports = [
      inputs.noctalia.homeModules.default
      # ^ Adjust this path based on what the upstream flake names its HM module
    ];

    xdg.configFile."noctalia/palettes/customStylix.json".text = let
      sc = config.lib.stylix.colors;
      hash = hex: "#${hex}";
    in builtins.toJSON {
      dark = {
        mPrimary           = hash sc.base0B;
        mOnPrimary         = hash sc.base00;
        mSecondary         = hash sc.base0D;
        mOnSecondary       = hash sc.base00; 
        mTertiary          = hash sc.base0E;
        mOnTertiary        = hash sc.base00;
        mError             = hash sc.base08;
        mOnError           = hash sc.base00;
        mSurface           = hash sc.base00;
        mOnSurface         = hash sc.base05;
        mSurfaceVariant    = hash sc.base02;
        mOnSurfaceVariant  = hash sc.base04;
        mOutline           = hash sc.base03;
        mShadow            = hash sc.base0F;
        mHover             = hash sc.base01;
        mOnHover           = hash sc.base06;
        
        terminal = {
          background       = hash sc.base00;
          foreground       = hash sc.base05;
          cursor           = hash sc.base05;
          cursorText       = hash sc.base00;
          selectionBg      = hash sc.base05;
          selectionFg      = hash sc.base00;
          
          normal = {
            black          = hash sc.base00;
            red            = hash sc.base08;
            green          = hash sc.base0B;
            yellow         = hash sc.base0A;
            blue           = hash sc.base0D;
            magenta        = hash sc.base0E;
            cyan           = hash sc.base0C;
            white          = hash sc.base05;
          };
          bright = {
            black          = hash sc.base03;
            red            = hash sc.base08;
            green          = hash sc.base0B;
            yellow         = hash sc.base0A;
            blue           = hash sc.base0D;
            magenta        = hash sc.base0E;
            cyan           = hash sc.base0C;
            white          = hash sc.base07;
          };
        };
      };
    };

    # 2. DEFINE and configure the program now that the option is imported
    programs.noctalia = {
      enable = true;
      settings = lib.recursiveUpdate baseSettings {
        theme = {
          mode = "dark";
          source = "custom";
          custom_palette = "customStylix";
        };
        wallpaper = {
          enabled = true;
          default.path = ./wallpaper.webp;
        };
        shell = {
          avatar_path = ./avatar.webp;
        };
      };
    };

  };
}

