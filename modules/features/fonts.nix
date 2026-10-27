# The typefaces every one of these machines expects to find.
#
# JetBrains Mono Nerd Font is the monospace default because the bar and the
# terminals draw glyphs from the Nerd Font range; the Noto set is here so a
# page in Chinese, Japanese or Korean is not a row of boxes, and the two colour
# emoji fonts because Noto covers most of them and twemoji fills the gaps.
#
# The rest of it is for documents that came from Microsoft Office, which is how
# coursework and job postings arrive. Without these a .pptx renders every
# single run in DejaVu Sans -- measured on a CSE 510 proposal deck, where
# `pdffonts` on a LibreOffice export listed nothing else -- and DejaVu's
# advance widths match none of the fonts the file asked for, so text overflows
# its boxes and lines rewrap.
{ ... }: {
  flake.modules.nixos.fonts = { pkgs, ... }: {
    fonts.packages = with pkgs; [
      nerd-fonts.jetbrains-mono
      noto-fonts
      noto-fonts-cjk-sans
      noto-fonts-cjk-serif
      noto-fonts-color-emoji
      twemoji-color-font

      # Metric-compatible with the Office fonts, which is the property that
      # matters: same advance widths means a document laid out on Windows
      # occupies the same space here, whatever the glyphs look like.
      #   liberation_ttf -> Arial, Times New Roman, Courier New
      #   carlito        -> Calibri
      #   caladea        -> Cambria
      # Each ships a fontconfig rule naming what it substitutes for, so no
      # configuration below is needed to make Calibri resolve to Carlito.
      liberation_ttf
      carlito
      caladea

      # The genuine article for the older set -- Arial, Times New Roman,
      # Georgia, Verdana, Tahoma, Trebuchet, Courier New. Worth having over the
      # metric clones alone when a document will be handed back to someone
      # reading it in Office.
      #
      # Two caveats. It is `unfreeRedistributable`, so a host importing this
      # aspect needs nixpkgs.config.allowUnfree -- workstation.nix sets it.
      # And it is not in the binary cache: it fetches the old self-extracting
      # installers from SourceForge and unpacks them at build time, so a fresh
      # machine needs those URLs (or tarballs.nixos.org, which mirrors fetchurl
      # by hash) to still answer. If they ever rot, dropping this line costs
      # only glyph shapes -- liberation_ttf already holds the metrics.
      corefonts
    ];

    fonts.fontconfig.defaultFonts = {
      monospace = [ "JetBrainsMono NF" ];
    };

    # Two fonts that no package can supply and fontconfig guesses badly at.
    #
    # Aptos is the default in Office since 2024 and is the theme font of every
    # deck made with a current PowerPoint -- which means it is what the body
    # text of those files actually renders in, so it matters more than any
    # family named explicitly inside them. Microsoft licenses it with Office
    # and there is no metric clone, so nixpkgs has nothing to install; left
    # alone, fontconfig falls through to DejaVu Sans.
    #
    # Segoe UI was worse: it resolved to "Noto Sans Arabic UI", which is a
    # fontconfig accident rather than a decision.
    #
    # Liberation Sans for both, chosen for shape rather than metrics since no
    # metric match exists: Aptos is a neo-grotesque, so Arial's proportions are
    # a closer read than Calibri's humanist ones. `binding="same"` keeps the
    # substitution from outranking a family the document names explicitly.
    fonts.fontconfig.localConf = ''
      <?xml version="1.0"?>
      <!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
      <fontconfig>
        <match target="pattern">
          <test name="family"><string>Aptos</string></test>
          <edit name="family" mode="assign" binding="same"><string>Liberation Sans</string></edit>
        </match>
        <match target="pattern">
          <test name="family"><string>Segoe UI</string></test>
          <edit name="family" mode="assign" binding="same"><string>Liberation Sans</string></edit>
        </match>
      </fontconfig>
    '';
  };
}
