{ self, inputs, ... }:
let
  slots = { inherit (self.lib.agentVm.instances) agent-0 agent-1; };

  # This machine's agents, as corkboard's fleet sees them
  # (~/corkboard/fleet/lib.nix, ~/corkboard/.agent/plans/agent-fleet.md): who
  # each works for (brains), what it can do (capabilities), where it can run
  # (environments), and the templates that put the three together. Each
  # template that runs as a VM is a nixosConfiguration of the same name.
  #
  # `mkFleet` refuses, at evaluation, any template that names an environment
  # lacking one of its needs, and any guest smaller than its capabilities
  # require.
  fleet = inputs.corkboard.lib.fleet.mkFleet {
    inherit (inputs.nixpkgs.lib) nixosSystem;

    brains = {
      # The work brain: Stable's mail, the vault in ~/second-brain, and the
      # repos it builds. Open egress since 2026-10-11 (see
      # my.agentVms.instances.brain-vm on omni-laptop for what that gave up).
      work = {
        modules = [ self.modules.nixos.brainVmConfiguration ];
        credentials = [ "graph" "github" "google" ];
      };

      # Pepper, the personal assistant (~/pepper/.agent/plans/pepper-prd.md),
      # added 2026-10-24. Allowlisted: it reads personal mail while holding
      # personal credentials, so the proxy is what stands between a prompt
      # injection and the internet. Each later addition to this list is
      # written down with its reason.
      pepper = {
        modules = [ self.modules.nixos.pepperVmConfiguration ];
        credentials = [ "google" "corkboard" ];
        egress = [
          # corkboard's Worker: tasks, plans and memory over MCP, and its
          # OAuth endpoints.
          "corkboard.matthewjurenka.workers.dev"

          # Google, read-only, for Phase 3 (calendar.readonly,
          # gmail.readonly). Each host is its API's rootUrl. No
          # accounts.google.com: consent runs on the host, so the guest can
          # spend a token but cannot start a consent of its own.
          "oauth2.googleapis.com"
          "www.googleapis.com"
          "gmail.googleapis.com"

          # Not yet: the Canvas ICS feed's host, until Phase 3 knows it.
        ];
      };
    };

    inherit slots;
    slotModules = [{
      # Who may log in to a slot over SSH: `agent-N-ssh` on this host.
      users.users.claude.openssh.authorizedKeys.keyFiles = [ ../hosts/pepper-vm/authorized-keys ];
      time.timeZone = "America/Phoenix";
    }];

    capabilities = {
      # Claude Code, the overlay and the package together. Every agent here
      # is Claude Code, so every template has it.
      claude-code = {
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

      # Building and testing a repo: corkboard's, as it is.
      inherit (inputs.corkboard.lib.fleet.capabilities) coding;

      # The host's GPU, and the X server that can use it. Its own capability
      # because it is the host's hardware being shared rather than a package
      # set, and because the boundary it widens is the host kernel's rather
      # than the network's.
      gpu = {
        modules = [ self.modules.nixos.brainVmGpu ];
        needs = [ "gpu" "display" ];
      };

      # A Steam client and the X tooling around it, so the `verse` protocol
      # work can be checked against a real client rather than the server's
      # serialiser alone. Renders on the GPU's X server.
      valheim = {
        modules = [ self.modules.nixos.brainVmValheim ];
        requires = [ "gpu" ];
      };

      # Chromium and a wallet extension, driveable from Python. Runs on the
      # X server `gpu` puts up.
      wallet-browser = {
        modules = [ self.modules.nixos.brainVmBrowser ];
        requires = [ "gpu" ];
      };

      # A niri session to show a browser in, on the host's screen.
      desktop = {
        modules = [ self.modules.nixos.niri ];
        needs = [ "display" ];
      };
    };

    environments = {
      # omni-laptop: KVM microVMs (~/corkboard/fleet/host), the host's GPU
      # and screen.
      local = {
        kind = "vm";
        provides = [ "gpu" "display" "kvm" ];
      };
    };

    templates = {
      # The work brain, and Valheim and the wallet browser alongside it, as
      # one guest until Valheim becomes a template of its own.
      brain-vm = {
        brain = "work";
        capabilities = [ "claude-code" "valheim" "gpu" "wallet-browser" ];
        environments = [ "local" ];
      };

      pepper-vm = {
        brain = "pepper";
        capabilities = [ "claude-code" ];
        environments = [ "local" ];
      };

      # A coding agent with no brain and no credentials, spawned into a
      # slot: `corkboard-fleet spawn coding --repo DIR <task>`. Its work
      # comes back as commits (`corkboard-fleet fetch`).
      coding = {
        capabilities = [ "claude-code" "coding" ];
        environments = [ "local" ];
        spawnable = true;
      };

      # The browser VM: Chromium with the Claude extension, the whole public
      # internet, and no brain's credentials.
      claude-vm = {
        modules = [ self.modules.nixos.claudeVmConfiguration ];
        capabilities = [ "desktop" ];
        environments = [ "local" ];
      };
    };
  };
in
{
  flake.lib.fleet = { inherit (fleet) templates environments slotEgress; };
  flake.nixosConfigurations = fleet.nixosConfigurations;
}
