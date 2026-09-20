{ self, inputs, ... }: {
  flake.nixosConfigurations.omni-laptop = inputs.nixpkgs.lib.nixosSystem {
    modules = [
      self.nixosModules.omniLaptopConfiguration
      self.nixosModules.claude-code
      self.nixosModules.niri
      self.nixosModules.myHomeManager
      self.nixosModules.user-matt
      inputs.stylix.nixosModules.stylix
      self.nixosModules.stylix
    ];
  };
}
