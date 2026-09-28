{ self, inputs, ... }: {
  flake.nixosConfigurations.vinkie-desktop = inputs.nixpkgs.lib.nixosSystem {
    modules = [
      self.nixosModules.vinkieDesktopConfiguration
      self.nixosModules.onepassword
      self.nixosModules.niri
      self.nixosModules.myHomeManager
      inputs.stylix.nixosModules.stylix
      self.nixosModules.stylix
      self.nixosModules.noctaliaGreeterAppearance
    ];
  };
}
