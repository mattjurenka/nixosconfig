{ self, inputs, ... }: {
  flake.nixosConfigurations.pepper-vm = inputs.nixpkgs.lib.nixosSystem {
    modules = [
      self.modules.nixos.pepperVmConfiguration
      # Pepper *is* Claude Code; this brings the overlay and the package.
      self.modules.nixos.claude-code
    ];
  };
}
