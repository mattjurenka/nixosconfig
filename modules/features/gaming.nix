# Steam.
#
# The override is not decoration: Proton titles here fail to start without
# libGLU in the runtime, and the same line was copied into all three host
# configurations before this was a feature of its own.
{ ... }: {
  flake.modules.nixos.gaming = { pkgs, ... }: {
    programs.steam = {
      enable = true;
    };
    programs.steam.package = pkgs.steam.override {
      extraPkgs = pkgs': with pkgs'; [
        libGLU
      ];
    };
  };
}
