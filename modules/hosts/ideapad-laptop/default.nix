{ self, inputs, ... }: {
  flake.nixosConfigurations.ideapad-laptop = inputs.nixpkgs.lib.nixosSystem {
    modules = [
      self.nixosModules.ideapadLaptopConfiguration
      self.nixosModules.niri
      self.nixosModules.myHomeManager
      self.nixosModules.user-matt
      inputs.stylix.nixosModules.stylix
      self.nixosModules.stylix
    ];
  };
}
