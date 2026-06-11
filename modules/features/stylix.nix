{ ... }:
{
  flake.nixosModules.stylix = { pkgs, lib, ... }: {
    stylix.enable = true;
    stylix.base16Scheme = "${pkgs.base16-schemes}/share/themes/monokai.yaml";
    stylix.image = pkgs.fetchurl {
      url = "https://getwallpapers.com/wallpaper/full/1/4/3/523784.jpg";
      hash = "sha256-S/6kgloXiIYI0NblT6YVXfqELApbdHGsuYe6S4JoQwQ=";
    };
  };
}
