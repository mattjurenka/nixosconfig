{ self, inputs, ... }: {
  flake.nixosConfigurations.omni-laptop = inputs.nixpkgs.lib.nixosSystem {
    modules = [
      self.nixosModules.omniLaptopConfiguration
      self.nixosModules.claudeVmHost
      self.nixosModules.claude-code
      self.nixosModules.onepassword
      self.nixosModules.niri
      self.nixosModules.myHomeManager
      inputs.stylix.nixosModules.stylix
      self.nixosModules.stylix
      self.nixosModules.noctaliaGreeterAppearance
    ];
  };
}
