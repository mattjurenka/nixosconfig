{ self, inputs, ... }: {
  flake.nixosConfigurations.ideapad-laptop = inputs.nixpkgs.lib.nixosSystem {
    modules = [
      # The shape every machine Matt sits at shares; see
      # modules/features/workstation.nix.
      self.modules.nixos.workstation
      self.modules.nixos.ideapadLaptopConfiguration
    ];
  };
}
