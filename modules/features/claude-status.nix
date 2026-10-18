# A taskbar readout of which Claude Code agent threads are waiting for input.
#
# Zed-first since the work moved into the editor: a square stands for a thread
# in Zed with something said in it, so the row reads like the threads sidebar
# rather than like a list of everything on the machine with a claude in it, and
# a click always lands in the editor. claude-ready-watch owns that rule and
# CLAUDE_READY_AGENTS=all is the way back to the old reading.
#
# Two surfaces, one reading: a row of 18x18 squares, one per session, coloured
# by whether that session is waiting on you and carrying two characters of its
# topic so one square can be told from the next. Normally the row lives in
# noctalia's bar. A fullscreen window in niri renders above the Top layer,
# which is where the bar lives, so the bar and the row disappear exactly when a
# game or a video is on -- and then the same row is drawn in the very top-left
# corner on the Overlay layer, where nothing can cover it.
{ self, ... }:
{
  # A registry of Claude Code sessions only ever covers its own machine, so an
  # agent VM runs this same watcher inside the guest to publish its reading
  # back through its outbox share, and the copy on this side merges it. Shared
  # from here so the two can never drift into reading each other wrongly.
  config.flake.lib.mkClaudeReadyWatch =
    { pkgs
    , # Where to find readings published by other machines. Empty for a guest,
      # which publishes rather than merges.
      remoteGlob ? ""
    }:
    pkgs.writeShellApplication {
      name = "claude-ready-watch";
      # `claude` is deliberately resolved from the session PATH rather than
      # pinned here: the hosts that share this home have no claude-code
      # overlay, and there the watcher simply reports no sessions and the
      # indicator hides itself.
      runtimeInputs = [ pkgs.jq pkgs.inotify-tools pkgs.coreutils pkgs.gnugrep pkgs.gnused ];
      bashOptions = [ "nounset" "pipefail" ];
      text = builtins.replaceStrings [ "@remoteGlob@" ] [ remoteGlob ] (
        builtins.readFile ./claude-status/claude-ready-watch.sh
      );
    };

  config.flake.modules.homeManager.claudeStatus =
    { pkgs, lib, config, ... }:
    let
      colors = config.lib.stylix.colors;
      noctaliaPackage = config.programs.noctalia.package;

      # Raising Zed, which is where the agent threads these squares stand for
      # actually live: its threads sidebar is the agent view over all of them,
      # and it is what the bar glyph opens now that the work moved into the
      # editor. It replaced `kitty claude agents`, which lists only the
      # sessions started in a terminal -- the exception rather than the rule
      # here since zed.nix.
      #
      # `zeditor` is looked for on the session PATH first on purpose:
      # home-manager installs it wrapped with the editor's own extraPackages
      # (nil, see zed.nix) and that wrapper lives in the profile, not in this
      # package, so starting the binary named here would be starting an editor
      # without its language servers. The store path is only the backstop for
      # a caller whose PATH has neither.
      zedOpen = pkgs.writeShellApplication {
        name = "claude-zed-open";
        text = ''
          zed=$(command -v zeditor || printf '%s' '${lib.getExe' config.programs.zed-editor.package "zeditor"}')
          exec "$zed" "$@"
        '';
      };

      # Both readings stream JSON lines and stay silent in between, so neither
      # of them polls anything.
      claudeReadyWatch = self.lib.mkClaudeReadyWatch {
        inherit pkgs;
        # Every agent VM's outbox, by shape rather than by name, so a new one
        # shows up in the bar by existing rather than by being configured here.
        remoteGlob = "/var/lib/*/outbox/.claude-sessions.json";
      };

      # How much of the plan the account has spent, for the two circles left of
      # the squares. Its own watcher because it is the only part of this that
      # asks a server anything: a host with no credentials, or no network, just
      # gets squares.
      claudeUsageWatch = pkgs.writeShellApplication {
        name = "claude-usage-watch";
        runtimeInputs = [ pkgs.jq pkgs.curl pkgs.coreutils ];
        bashOptions = [ "nounset" "pipefail" ];
        text = builtins.readFile ./claude-status/claude-usage-watch.sh;
      };

      niriFullscreenWatch = pkgs.writeShellApplication {
        name = "niri-fullscreen-watch";
        runtimeInputs = [ pkgs.jq pkgs.niri ];
        bashOptions = [ "nounset" "pipefail" ];
        text = builtins.readFile ./claude-status/niri-fullscreen-watch.sh;
      };

      # The same reading, pushed to a topic a phone can poll. Separate from the
      # watcher so that nothing about the bar depends on a network being there.
      ntfyPublish = pkgs.writeShellApplication {
        name = "claude-ntfy-publish";
        runtimeInputs = [ pkgs.jq pkgs.curl pkgs.coreutils ];
        bashOptions = [ "nounset" "pipefail" ];
        text = builtins.readFile ./claude-status/claude-ntfy-publish.sh;
      };

      # What a square does when it is clicked. `claude` comes from the session
      # PATH for the same reason the watcher's does.
      sessionFocus = pkgs.writeShellApplication {
        name = "claude-session-focus";
        runtimeInputs = [
          pkgs.jq
          pkgs.niri
          pkgs.procps
          pkgs.coreutils
          config.programs.kitty.package
          # For a square standing for a Zed agent thread, which is reached by
          # the editor rather than by a terminal.
          zedOpen
          # flock, so two clicks cannot each open a window for one project.
          pkgs.util-linux
        ];
        bashOptions = [ "nounset" "pipefail" ];
        # Which ssh URL names a thread running in an agent VM, as one
        # origin -> prefix object. The address comes from the same plan
        # zed.nix builds its ssh_connections from, and the user is the one it
        # logs in as, so a click and the editor cannot end up pointed at
        # different machines.
        text = builtins.replaceStrings [ "@vmProjects@" ] [
          (builtins.toJSON (
            lib.mapAttrs (_: vm: "ssh://claude@${vm.guestAddress}") self.lib.agentVm.instances
          ))
        ] (builtins.readFile ./claude-status/claude-session-focus.sh);
      };

      # noctalia installs plugins out of a source directory holding a catalog
      # and one subdirectory per plugin. It is generated rather than committed
      # as-is so the widget can name the watcher by its store path instead of
      # hoping for a PATH.
      pluginSource = pkgs.runCommand "noctalia-claude-status-plugin" { } ''
        mkdir -p "$out/claude-status"
        cp ${./claude-status/plugin/catalog.toml} "$out/catalog.toml"
        cp ${./claude-status/plugin/plugin.toml} "$out/claude-status/plugin.toml"
        substitute ${./claude-status/plugin/indicator.luau} "$out/claude-status/indicator.luau" \
          --replace-fail '@watch@' '${lib.getExe claudeReadyWatch}' \
          --replace-fail '@usage@' '${lib.getExe claudeUsageWatch}' \
          --replace-fail '@focus@' '${lib.getExe sessionFocus}' \
          --replace-fail '@agents@' '${lib.getExe zedOpen}'
      '';

      # noctalia copies a plugin out of its source when it is enabled, so a new
      # build of the widget never reaches a shell that is already running. The
      # source path is named in the script on purpose: it changes with every
      # new build of the plugin, which is what makes systemd notice and run
      # this again, and what keeps it idle on a rebuild that changed nothing
      # here. Failures are silent by design -- a shell that is not up yet will
      # export the plugin itself when it starts.
      reloadPlugin = pkgs.writeShellApplication {
        name = "claude-status-plugin-reload";
        runtimeInputs = [ noctaliaPackage ];
        bashOptions = [ "nounset" "pipefail" ];
        text = ''
          echo "source is ${pluginSource}"

          for _ in $(seq 20); do
            if noctalia msg plugins disable jurenka/claude-status >/dev/null 2>&1; then
              noctalia msg plugins enable jurenka/claude-status >/dev/null 2>&1 || true
              exit 0
            fi
            sleep 1
          done
        '';
      };

      # The same colours the bar widget asks the palette for: primary for a
      # session that is waiting on you, secondary for one still working, and
      # the companion to primary for a label written across a filled square.
      # Spelled as base16 slots here because quickshell has no palette to ask
      # -- the mapping is the one in noctalia.nix, which is where primary and
      # on_primary get their values from these same two slots.
      dot = pkgs.runCommand "claude-ready-dot.qml" { } ''
        substitute ${./claude-status/dot.qml} "$out" \
          --replace-fail '@readyColor@' '#${colors.base0B}' \
          --replace-fail '@readyLabelColor@' '#${colors.base00}' \
          --replace-fail '@busyColor@' '#${colors.base0D}' \
          --replace-fail '@claudeWatch@' '${lib.getExe claudeReadyWatch}' \
          --replace-fail '@focus@' '${lib.getExe sessionFocus}' \
          --replace-fail '@fullscreenWatch@' '${lib.getExe niriFullscreenWatch}'
      '';
    in
    {
      # The watchers print to stdout, the focus helper takes one session from
      # them and the publisher reads a stream of them, so each one is worth
      # running by hand when the indicator does something surprising.
      home.packages = [ claudeReadyWatch claudeUsageWatch niriFullscreenWatch sessionFocus ntfyPublish zedOpen ];

      # niri can say which window a process belongs to, but not which tab
      # inside it, and a square should land on the tab its session is actually
      # running in. kitty will answer that over a socket, one per kitty
      # process; socket-only keeps the answer away from anything that merely
      # prints escape sequences into a terminal.
      programs.kitty.settings = {
        allow_remote_control = "socket-only";
        listen_on = "unix:\${XDG_RUNTIME_DIR}/kitty.sock";
      };

      # noctalia-config.toml names this path as a plugin source.
      xdg.configFile."noctalia-plugins".source = pluginSource;

      systemd.user.services.claude-ready-dot = {
        Unit = {
          Description = "Claude Code readiness dot, drawn over fullscreen windows";
          PartOf = [ "graphical-session.target" ];
          After = [ "graphical-session.target" ];
        };

        Service = {
          ExecStart = "${pkgs.quickshell}/bin/quickshell -p ${dot}";
          Restart = "on-failure";
          RestartSec = 5;
        };

        Install.WantedBy = [ "graphical-session.target" ];
      };

      # Not tied to the graphical session: what this feeds is a phone, which
      # wants the reading whether or not a compositor is up on this machine.
      # It idles harmlessly with no topic file, which is the state of every
      # host that has not been pointed at a topic.
      systemd.user.services.claude-status-ntfy = {
        Unit.Description = "Publish Claude Code session state to an ntfy topic";

        Service = {
          ExecStart = pkgs.writeShellScript "claude-status-ntfy" ''
            ${lib.getExe claudeReadyWatch} | ${lib.getExe ntfyPublish}
          '';
          Restart = "always";
          RestartSec = 30;
        };

        Install.WantedBy = [ "default.target" ];
      };

      systemd.user.services.claude-status-plugin-reload = {
        Unit = {
          Description = "Hand a rebuilt Claude status widget to the running shell";
          PartOf = [ "graphical-session.target" ];
          After = [ "graphical-session.target" ];
        };

        Service = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = lib.getExe reloadPlugin;
        };

        Install.WantedBy = [ "graphical-session.target" ];
      };
    };
}
