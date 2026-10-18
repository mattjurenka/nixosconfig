{ self, inputs, ... }: {
  flake.nixosConfigurations.omni-laptop = inputs.nixpkgs.lib.nixosSystem {
    modules = [
      self.modules.nixos.omniLaptopConfiguration
      self.modules.nixos.agentVmHost
      self.modules.nixos.claude-code
      self.modules.nixos.claude-desktop
      self.modules.nixos.opcode
      self.modules.nixos.onepassword
      self.modules.nixos.niri
      self.modules.nixos.myHomeManager
      inputs.stylix.nixosModules.stylix
      self.modules.nixos.stylix
      self.modules.nixos.noctaliaGreeterAppearance
    ];
  };
}
