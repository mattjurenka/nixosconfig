{ self, inputs, ... }: {
  # The host-side plumbing for the agent VMs lives in corkboard
  # (~/corkboard/fleet/host); this flake installs it, with the plans from
  # ./plan.nix. Hosts that run VMs import this aspect and set
  # `my.agentVms.instances`.
  flake.modules.nixos.agentVmHost = { config, lib, ... }: {
    imports = [ inputs.corkboard.nixosModules.fleetHost ];
    my.agentVms.plans = self.lib.agentVm.instances;
    # Built with the host, so starting a VM evaluates nothing. Slots are
    # left out: their guest is whichever template a spawn picks.
    my.agentVms.runners = lib.mapAttrs
      (name: _: self.nixosConfigurations.${name}.config.system.build.vm)
      (lib.filterAttrs (name: inst: !inst.slot && self.nixosConfigurations ? ${name})
        config.my.agentVms.instances);
  };
}
