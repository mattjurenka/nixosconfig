# Zed, with Claude Code in its agent panel.
#
# The agent is a separate process speaking ACP (the Agent Client Protocol) to
# the editor: Zed owns the thread UI and the diffs, Claude Code owns the model,
# the tools and the auth. Zed can install such an agent itself from its ACP
# registry, which fetches it with node at runtime into ~/.local -- declaring it
# as a custom agent below points the editor at a store path instead, so the
# version is pinned by our flake.lock like everything else.
#
# Colours and fonts come from stylix's zed target, which applies on its own
# because programs.zed-editor is enabled here.
{ self, ... }: {
  flake.modules.homeManager.zed = { pkgs, lib, ... }: {
    # This machine's answer to `claude-acp`, the one command name the agent
    # entry below names. All it does is pick the store path, because that is the
    # part that cannot be written down in a settings file shared with another
    # machine; brain-vm's own `claude-acp` (environment.systemPackages in
    # modules/hosts/brain-vm/configuration.nix) loads the guest's credentials
    # first and then execs the guest's copy.
    home.packages = [
      (pkgs.writeShellApplication {
        name = "claude-acp";
        text = ''exec ${lib.getExe pkgs.claude-agent-acp} "$@"'';
      })
    ];

    programs.zed-editor = {
      enable = true;

      # Zed finds language servers on its own PATH, not the login shell's.
      extraPackages = [ pkgs.nil ];

      userSettings = {
        # claude-agent-acp is the Claude Agent SDK wrapped in ACP. nixpkgs
        # builds it with CLAUDE_CODE_EXECUTABLE pointed at our claude-code, so
        # threads here run the same binary -- and the same subscription login
        # in ~/.claude -- as `claude` in a terminal. `/login` inside a thread
        # if it ever asks.
        #
        # One entry, not one per machine, and the reason is that there is one
        # settings file but two machines running what it says. Zed starts an
        # external agent wherever the project lives: on this host for a local
        # project, and through the SSH connection below -- inside brain-vm --
        # for a remote one. A store path from this machine's Nix means nothing
        # in the guest, so naming one here left half the projects answering with
        # `exit status 127` and a missing file. Offering one entry per machine
        # instead only moved the choice onto Zed, which remembers the last agent
        # per project *by name*: rename or drop an entry and every thread that
        # used it says `Custom agent server ... is not registered` until the
        # agent is picked again (that memory lives in scoped_kv_store in
        # ~/.local/share/zed/db, not in this file).
        #
        # Picked where, because this is the part that is not discoverable:
        # `agent::ToggleNewThreadMenu`, ctrl-alt-shift-n. The "+" at the top of
        # the threads sidebar is `agents_sidebar::NewThreadInGroup` (ctrl-n) and
        # lists no agents at all -- it opens a thread with whatever this project
        # last used, which on a fresh workspace is Zed's own agent, and that one
        # has no provider signed in: "no language model configured". Settings ->
        # External Agents is where to confirm an entry here was registered.
        #
        # So the name stays fixed and each machine supplies the command behind
        # it. `claude-acp` is on PATH here from home.packages above and in the
        # guest from its own environment.systemPackages, pointing at that
        # machine's store path -- so a remote thread holds the guest's
        # credentials, sees only the guest's mounts and reaches the network
        # through the host's forward chain, while a local one runs with Matt's
        # login and Matt's files, and neither has to be chosen in the UI.
        #
        # `bash` at the system profile path is the one *absolute* path both
        # machines have, and it is here to resolve that name at the far end
        # rather than in this file. One word per argument, deliberately: Zed
        # rewrites this file when a setting changes in its UI, and it rewrites
        # `args` by splitting on whitespace -- on Oct 17 a `bash -c` script came
        # back as ["if", "[", "-x", ...] and every thread died on a syntax
        # error. A single-token argv survives that round trip unchanged, which
        # is why the dispatch lives in a script on PATH and not in the JSON.
        agent_servers."Claude Code" = {
          type = "custom";
          command = "/run/current-system/sw/bin/bash";
          args = [ "-c" "claude-acp" ];
        };

        # The swarm's actual mechanism, so it is written down somewhere: Zed's
        # threads sidebar runs threads in parallel, and each thread can be given
        # its own git worktree from the picker in its title bar. That is what
        # keeps two agents off each other's uncommitted changes -- the VM is one
        # filesystem, so without a worktree per thread they share an index and a
        # HEAD. `git worktree add` runs in the guest, in the checkout the thread
        # is rooted in, which is why the projects below are the clones under
        # /var/lib/second-brain/work rather than /opt/second-brain: the repo
        # shares are read-only virtiofs mounts of Matt's own working trees.
        #
        # Concurrency is bounded by the guest, not by Zed: 6 vCPUs and 10 GiB
        # (virtualisation.cores/memorySize there, with a 14 GiB cgroup ceiling
        # on the host), already carrying the heartbeat's own session. Three or
        # four threads is the shape that fits; a dozen is how the host froze on
        # Oct 10.
        ssh_connections = [{
          # From the address plan, so this cannot drift from the VM it points
          # at: modules/features/agent-vm/plan.nix owns 10.78.0.2.
          host = self.lib.agentVm.instances.brain-vm.guestAddress;
          username = "claude";

          # The same two options brain-vm-ssh passes, for the same reason: the
          # guest regenerates its host keys whenever its disk is reinstalled,
          # and the forward chain means there is nothing else that could be at
          # the far end to impersonate. A stale known_hosts entry here would be
          # a security warning for an expected event.
          args = [
            "-o"
            "StrictHostKeyChecking=no"
            "-o"
            "UserKnownHostsFile=/dev/null"
            "-o"
            "LogLevel=ERROR"
          ];

          nickname = "brain-vm";

          # Zed remembers whatever is opened, so this is a starting point rather
          # than the list. Per repository rather than the parent directory that
          # holds them, because the git panel and the worktree picker -- which
          # is what makes a thread safe to run beside another one -- are
          # per-repository: a project rooted at the parent sees six repos and
          # offers worktrees in none of them. The parent is last, for finding
          # whatever the brain has cloned since.
          projects = [
            { paths = [ "/var/lib/second-brain/work/baum-monorepo" ]; }
            { paths = [ "/var/lib/second-brain/work/verse" ]; }
            { paths = [ "/var/lib/second-brain/work" ]; }
          ];

          # Never fetch a server binary and never push one: the guest supplies
          # it from this same nixpkgs (systemd.tmpfiles in brain-vm's
          # configuration.nix), because the build zed.dev serves is dynamically
          # linked against a loader NixOS does not have at that path. Uploading
          # it over SSH would move the same unusable binary.
          upload_binary_over_ssh = false;
        }];

        # Command output in a thread, folded until asked for. Zed expands a
        # terminal card by default -- "showing the whole command output", per
        # its own description of this key -- which puts every byte a command
        # printed between what the agent said before it and what it says next.
        # The card header still names the command, so what ran stays on the
        # page; only its output folds away, and the card still opens on click.
        #
        # `agent.expand_edit_card` is the same knob for diffs and is left
        # alone on purpose: a diff is the work rather than the noise.
        #
        # Not `expand_terminal_command`, which clamps the command text itself:
        # it landed after 1.20.1 (zed#63328) and this version would take it as
        # a key it does not know, which is the "Property is not allowed"
        # squiggle rather than an error.
        agent.expand_terminal_card = false;

        # To match the vscodevim setup in matthew-home.nix; drop this line if
        # Zed's own bindings turn out to be preferable.
        vim_mode = true;

        # Zed's bundled Copilot-style predictions are a separate paid thing
        # from the agent panel, and the sign-in nag is noise without it.
        # `features.edit_prediction_provider` was the old spelling and 1.20
        # dropped it: the key still parses (Zed ignores what it does not know)
        # but its own schema rejects it, which is the "Property features is not
        # allowed" squiggle on this file.
        edit_predictions.provider = "none";
      };
    };
  };
}
