{ inputs, ... }: {
  # The agent VMs this flake's hosts and guests know about. Each is a plan from
  # corkboard's `lib.fleet.mkPlan` (~/corkboard/fleet/plan.nix): its own /24,
  # tap device and nftables table. The host gets the set through
  # ./host.nix, and each guest in modules/hosts/* reads its own entry, so the
  # two can never drift apart.
  #
  # Adding a VM means adding an entry to `instances` and a nixosConfiguration
  # under modules/hosts/; nothing else needs to know about it.
  flake.lib.agentVm =
    let
      mkPlan = inputs.corkboard.lib.fleet.mkPlan;
    in
    {
      inherit mkPlan;

      instances = {
        # The browser VM: Chromium with the Claude extension, and the whole
        # public internet, because that is the job.
        claude-vm = mkPlan {
          name = "claude-vm";
          interface = "clvm0";
          octet = 77;
          mac = "52:54:00:c1:a0:02";
        };

        # The second brain: headless, no browser, and no route off this
        # machine except a proxy that will only resolve four domains. It holds
        # a token that can read the whole Stable mailbox, so an open internet
        # connection would be an exfiltration channel rather than a feature.
        brain-vm = mkPlan {
          name = "brain-vm";
          interface = "brvm0";
          octet = 78;
          mac = "52:54:00:c1:a0:03";
          # Three, raised from one on 2026-10-11. The brain holds a long-running
          # `claude` session on one console for hours at a time, which left no way
          # to look at anything -- `systemctl status`, a log, the vault -- without
          # detaching from it first. Two is what was asked for; the third is
          # because the marginal cost is a socket file and a blocked shell, and
          # discovering the limit a second time is more expensive than that.
          consoles = 3;
        };

        # Pepper, the personal assistant (~/pepper): headless, and no route
        # off this machine but the filtering proxy. It reads personal mail
        # and the calendar, so it is the guest the allowlist is for now. One
        # console, because its sessions come in over SSH; the console is for
        # the first login and for a guest that did not boot.
        pepper-vm = mkPlan {
          name = "pepper-vm";
          interface = "ppvm0";
          octet = 79;
          mac = "52:54:00:c1:a0:04";
        };

      };
    };
}
