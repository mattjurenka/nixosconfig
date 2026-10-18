# The typefaces every one of these machines expects to find.
#
# JetBrains Mono Nerd Font is the monospace default because the bar and the
# terminals draw glyphs from the Nerd Font range; the Noto set is here so a
# page in Chinese, Japanese or Korean is not a row of boxes, and the two colour
# emoji fonts because Noto covers most of them and twemoji fills the gaps.
{ ... }: {
  flake.modules.nixos.fonts = { pkgs, ... }: {
    fonts.packages = with pkgs; [
      nerd-fonts.jetbrains-mono
      noto-fonts
      noto-fonts-cjk-sans
      noto-fonts-cjk-serif
      noto-fonts-color-emoji
      twemoji-color-font
    ];

    fonts.fontconfig.defaultFonts = {
      monospace = [ "JetBrainsMono NF" ];
    };
  };
}
