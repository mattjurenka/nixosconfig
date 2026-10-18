{ self, inputs, ... }: {
  flake.nixosConfigurations.omni-laptop = inputs.nixpkgs.lib.nixosSystem {
    modules = [
      self.nixosModules.omniLaptopConfiguration
      self.nixosModules.agentVmHost
      self.nixosModules.claude-code
      self.nixosModules.claude-desktop
      self.nixosModules.opcode
      self.nixosModules.onepassword
      self.nixosModules.niri
      self.nixosModules.myHomeManager
      inputs.stylix.nixosModules.stylix
      self.nixosModules.stylix
      self.nixosModules.noctaliaGreeterAppearance
    ];
  };
}
