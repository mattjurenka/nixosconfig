{ ... }: {
  # opencode (sst/opencode): a terminal coding agent in the same vein as
  # Claude Code, but provider-agnostic. Taken straight from nixpkgs.
  flake.modules.nixos.opencode = { pkgs, ... }: {
    environment.systemPackages = [ pkgs.opencode ];
  };
}
