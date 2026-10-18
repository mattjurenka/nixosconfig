{ ... }:
{
  flake.modules.nixos.stylix = { pkgs, lib, ... }: {

    stylix = {
      enable = true;
      base16Scheme = "${pkgs.base16-schemes}/share/themes/monokai.yaml";
      polarity = "dark";
      fonts = {
        monospace = {
          package = pkgs.nerd-fonts.jetbrains-mono;
          # The long name, which is the one in the font's own name table.
          # fontconfig answers to both (`fc-list` shows "JetBrainsMono NF" as
          # well) so everything stylix touches was happy either way, but Zed
          # enumerates families itself and only knows the long one -- the short
          # alias came back as "Value is not accepted" against a list of every
          # font on the machine. Same face: "NF" is the proportional-icon
          # variant, "NFM"/"Nerd Font Mono" is the other one.
          name = "JetBrainsMono Nerd Font";
        };
      };
    };
  };
}
