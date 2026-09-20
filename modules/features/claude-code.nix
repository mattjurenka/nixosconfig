{ self, inputs, ... }: {
  flake.nixosModules.claude-code = { pkgs, ... }: {
    # Builds the upstream binary against our own nixpkgs rather than the one
    # claude-code-nix pins, so we don't instantiate a second nixpkgs.
    nixpkgs.overlays = [ inputs.claude-code.overlays.default ];

    # Claude Code is unfree; hosts importing this need allowUnfree.
    environment.systemPackages = [ pkgs.claude-code ];
  };
}
