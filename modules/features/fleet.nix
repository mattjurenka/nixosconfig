{ self, inputs, ... }:
let
  # Claude Code, the overlay and the package together. Every agent here is
  # Claude Code, so every template has it, here and in the cloud.
  claudeCode = {
    modules = [ self.modules.nixos.claude-code ];
    targets = [ "vm" "oci" ];
    egress = [
      # From brain-vm's allowlist (taken from Claude Code's documented
      # network requirements; the PRD's console.anthropic.com and
      # statsig.anthropic.com were the earlier wrong guess).
      # api.anthropic.com carries the API and the WebFetch check;
      # platform.claude.com OAuth token exchange and refresh; claude.ai
      # and claude.com the sign-in; code.claude.com the docs lookups.
      "api.anthropic.com"
      "platform.claude.com"
      "claude.ai"
      "claude.com"
      "code.claude.com"
    ];
  };

  # The browser VM: Chromium with the Claude extension, the whole public
  # internet, a niri session to show it in, and no brain's credentials.
  # omni-laptop runs it by hand (`claude-vm`). Spawned agents are corkboard's
  # (services.corkboard.fleet, in ./corkboard.nix), not this flake's.
  claudeVm = inputs.nixpkgs.lib.nixosSystem {
    modules = [ self.modules.nixos.claudeVmConfiguration self.modules.nixos.niri ];
  };

  # The droplet (valheim.jurenka.software): the `cloud` environment, one
  # slot beside the Verse stack that already lives there, on Ubuntu rather
  # than NixOS. Its host side isn't a NixOS module but files put there by
  # hand (~/corkboard/.agent/handoff-sessions.md); only the guests are built
  # here, and copied over. Verse leaves it about 1.5 GiB, so its one
  # template is a slimmer `coding`: the same tools and egress, one core of
  # the two, and memory that fits.
  cloudFleet = inputs.corkboard.lib.fleet.mkFleet {
    inherit (inputs.nixpkgs.lib) nixosSystem;
    # corkboard, who runs the slot there: 9p passes uids through. A uid
    # under 1000 is a system user's to NixOS, so the guest's claude is one,
    # with the home a normal user would have. Its group is corkboard's too,
    # or virtiofsd, unprivileged, refuses what it creates.
    ownerUid = 994;
    slotModules = [
      ({ lib, ... }: {
        time.timeZone = "America/Phoenix";
        users.users.claude = {
          isNormalUser = lib.mkForce false;
          isSystemUser = true;
          home = "/home/claude";
          createHome = true;
          useDefaultShell = true;
          group = lib.mkForce "corkboard";
        };
        users.groups.corkboard.gid = 985;
      })
    ];
    capabilities = {
      claude-code = claudeCode;
      coding-lite = {
        inherit (inputs.corkboard.lib.fleet.capabilities.coding) modules egress targets;
        memory = 1536;
        cores = 1;
        disk = 8192;
      };
      # A Forgejo Actions job's runner and tools (~/corkboard/fleet/caps/actions.nix).
      inherit (inputs.corkboard.lib.fleet.capabilities) actions;
    };
    environments.cloud = {
      kind = "vm";
      provides = [ "kvm" ];
    };
    templates.cloud-coding = {
      capabilities = [ "claude-code" "coding-lite" ];
      environments = [ "cloud" ];
      spawnable = true;
      modules = [{
        virtualisation.memorySize = 1536;
        virtualisation.cores = 1;
      }];
    };
    # One Forgejo Actions job (`runs-on: droplet`), queued by fleetd
    # (~/corkboard/fleet/fleetd/actions.ts) like any spawn. No Claude Code.
    templates.ci = {
      capabilities = [ "actions" ];
      environments = [ "cloud" ];
      spawnable = true;
      modules = [{
        virtualisation.memorySize = 1536;
        virtualisation.cores = 2;
      }];
    };
  };
in
{
  flake.lib.cloudFleet = { inherit (cloudFleet) templates slotEgress; };
  flake.nixosConfigurations = { claude-vm = claudeVm; } // cloudFleet.nixosConfigurations;
}
