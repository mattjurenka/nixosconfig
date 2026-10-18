{ self, inputs, ... }: {
  flake.nixosConfigurations.vinkie-desktop = inputs.nixpkgs.lib.nixosSystem {
    modules = [
      self.modules.nixos.vinkieDesktopConfiguration
      self.modules.nixos.onepassword
      self.modules.nixos.niri
      self.modules.nixos.myHomeManager
      inputs.stylix.nixosModules.stylix
      self.modules.nixos.stylix
      self.modules.nixos.noctaliaGreeterAppearance
    ];
  };
}
