{ ... }: {
  # Kiro: AWS's agentic IDE (a VS Code fork) and its terminal agent,
  # kiro-cli. Both unfree, taken straight from nixpkgs; workstation.nix
  # sets allowUnfree.
  flake.modules.nixos.kiro = { pkgs, ... }: {
    environment.systemPackages = [ pkgs.kiro pkgs.kiro-cli ];
  };
}
