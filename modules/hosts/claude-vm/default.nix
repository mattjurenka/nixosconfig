{ self, inputs, ... }: {
  flake.nixosConfigurations.claude-vm = inputs.nixpkgs.lib.nixosSystem {
    modules = [
      self.nixosModules.claudeVmConfiguration
      self.nixosModules.niri
    ];
  };
}
