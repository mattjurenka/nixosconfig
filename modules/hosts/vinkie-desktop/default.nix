{ self, inputs, ... }: {
  flake.nixosConfigurations.vinkie-desktop = inputs.nixpkgs.lib.nixosSystem {
    modules = [
      self.nixosModules.vinkieDesktopConfiguration
      self.nixosModules.niri
      self.nixosModules.myHomeManager
      self.nixosModules.user-matt
      inputs.stylix.nixosModules.stylix
      self.nixosModules.stylix
    ];
  };
}
