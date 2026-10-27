{ self, inputs, ... }: {
  # The host-side plumbing for the agent VMs lives in corkboard
  # (~/corkboard/fleet/host); this flake installs it, with the plans from
  # ./plan.nix. Hosts that run VMs import this aspect and set
  # `my.agentVms.instances`.
  flake.modules.nixos.agentVmHost = {
    imports = [ inputs.corkboard.nixosModules.fleetHost ];
    my.agentVms.plans = self.lib.agentVm.instances;
  };
}
