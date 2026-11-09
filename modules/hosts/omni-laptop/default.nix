{ self, inputs, ... }: {
  flake.nixosConfigurations.omni-laptop = inputs.nixpkgs.lib.nixosSystem {
    modules = [
      # The shape every machine Matt sits at shares; see
      # modules/features/workstation.nix.
      self.modules.nixos.workstation
      self.modules.nixos.omniLaptopConfiguration

      # This host only.
      self.modules.nixos.agentVmHost
      self.modules.nixos.claude-code
      self.modules.nixos.claude-desktop
      self.modules.nixos.corkboard
      self.modules.nixos.expressvpn
      self.modules.nixos.lagwatch
      self.modules.nixos.opencode
    ];
  };
}
