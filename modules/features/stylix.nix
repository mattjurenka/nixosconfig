{ ... }:
{
  flake.nixosModules.stylix = { pkgs, lib, ... }: {

    stylix = {
      enable = true;
      base16Scheme = "${pkgs.base16-schemes}/share/themes/monokai.yaml";
      polarity = "dark";
      fonts = {
        monospace = {
          package = pkgs.nerd-fonts.jetbrains-mono;
          name = "JetBrainsMono NF";
        };
      };
    };
  };
}
