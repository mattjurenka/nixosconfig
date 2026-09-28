# modules/features/noctalia.nix
{ inputs, lib, ... }:

let 
  baseSettings = builtins.fromTOML (builtins.readFile ./noctalia-config.toml);

  # Noctalia colour roles -> stylix base16 slots. Shared by the shell palette
  # and the greeter so the login screen matches the desktop.
  paletteRoles = {
    primary            = "base0B";
    on_primary         = "base00";
    secondary          = "base0D";
    on_secondary       = "base00";
    tertiary           = "base0E";
    on_tertiary        = "base00";
    error              = "base08";
    on_error           = "base00";
    surface            = "base00";
    on_surface         = "base05";
    surface_variant    = "base02";
    on_surface_variant = "base04";
    outline            = "base03";
    shadow             = "base0F";
    hover              = "base01";
    on_hover           = "base06";
  };

  # The greeter uses the role names as-is; the shell wants e.g. mOnSurfaceVariant.
  capitalize = s: lib.toUpper (lib.substring 0 1 s) + lib.substring 1 (-1) s;
  shellRoleName = role: "m" + lib.concatMapStrings capitalize (lib.splitString "_" role);

  mkPalette = sc: nameFn: lib.mapAttrs' (role: base:
    lib.nameValuePair (nameFn role) "#${sc.${base}}"
  ) paletteRoles;
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
      dark = mkPalette sc shellRoleName // {
        
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

  # The greeter runs before any user session, so it can't see the shell's
  # palette. It reads only the manifest that the shell's "Sync Now" button
  # writes, so generate that manifest from the same stylix colours instead.
  config.flake.nixosModules.noctaliaGreeterAppearance = { config, pkgs, ... }: let
    appearance = pkgs.writeText "noctalia-greeter-appearance.json" (builtins.toJSON {
      version = 1;
      theme_mode = "dark";
      palette = mkPalette config.lib.stylix.colors lib.id;
      wallpaper = {
        path = "${./wallpaper.webp}";
        fill_mode = "crop";
      };
    });
  in {
    systemd.tmpfiles.settings."11-noctalia-greeter-appearance" = {
      "/var/lib/noctalia-greeter/appearance.json"."L+".argument = "${appearance}";
    };

    # The greeter remembers the last colour scheme in greeter.conf and saves it
    # on every login, so a "Noctalia" choice from before the manifest existed
    # sticks forever. Reset it to the manifest's scheme each time greetd starts.
    systemd.services.greetd.preStart = let
      user = config.services.greetd.settings.default_session.user;
    in ''
      conf=/var/lib/noctalia-greeter/greeter.conf
      touch "$conf"
      ${pkgs.gnused}/bin/sed -i '/^[[:space:]]*scheme[[:space:]]*=/d' "$conf"
      echo 'scheme=Synced' >> "$conf"
      chown ${user}: "$conf"
      chmod 0644 "$conf"
    '';
  };
}

