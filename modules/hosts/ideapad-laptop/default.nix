{ self, inputs, ... }: {
  flake.nixosConfigurations.ideapad-laptop = inputs.nixpkgs.lib.nixosSystem {
    modules = [
      self.nixosModules.ideapadLaptopConfiguration
      self.nixosModules.myHomeManager
    ];
  };
}
