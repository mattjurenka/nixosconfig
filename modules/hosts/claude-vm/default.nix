{ self, inputs, ... }: {
  flake.nixosConfigurations.claude-vm = inputs.nixpkgs.lib.nixosSystem {
    modules = [
      self.modules.nixos.claudeVmConfiguration
      self.modules.nixos.niri
    ];
  };
}
