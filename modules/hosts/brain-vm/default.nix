{ self, inputs, ... }: {
  flake.nixosConfigurations.brain-vm = inputs.nixpkgs.lib.nixosSystem {
    modules = [
      self.modules.nixos.brainVmConfiguration
      # The brain *is* Claude Code, so the guest needs it; this module brings
      # the overlay and the package together.
      self.modules.nixos.claude-code
      # A Steam client and the X tooling around it, so the `verse` protocol
      # work can be checked against a real client rather than the server's
      # serialiser alone. Separate file because it is a self-contained
      # widening of what the guest can do, not part of what the guest *is*.
      self.modules.nixos.brainVmValheim
      # The host's GPU, and the X server that can use it. Separate from the
      # Valheim module because it is the host's hardware being shared rather
      # than a package set, and because the boundary it widens is the host
      # kernel's rather than the network's. Ordered after it for reading: the
      # client is the reason, this is the mechanism.
      self.modules.nixos.brainVmGpu
    ];
  };
}
