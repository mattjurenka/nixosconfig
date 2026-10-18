{ self, inputs, ... }: {
  flake.nixosConfigurations.ideapad-laptop = inputs.nixpkgs.lib.nixosSystem {
    modules = [
      self.modules.nixos.ideapadLaptopConfiguration
      self.modules.nixos.onepassword
      self.modules.nixos.niri
      self.modules.nixos.myHomeManager
      inputs.stylix.nixosModules.stylix
      self.modules.nixos.stylix
      self.modules.nixos.noctaliaGreeterAppearance
    ];
  };
}
