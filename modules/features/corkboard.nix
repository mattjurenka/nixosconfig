# corkboard: Neovim in the browser, with the board and agent panels beside it
# (~/corkboard). Installed here as an app rather than run from a dev shell:
# the bridge as a user service, and a launcher that opens it in corkboard's
# Electron window (corkboard-app, from app/ in its flake).
#
# Electron rather than a Chromium app window for the keys: Chromium keeps
# some for itself even there (Ctrl+W closes the window, and Ctrl+W is half
# of Vim's window commands), and the Electron window has no menu and so no
# shortcuts, bar F5 to reload and F12 for devtools. Every other key reaches
# Neovim.
#
# The package comes from corkboard's own flake, a `path:` input, so an edit
# there reaches this machine on `nix flake update corkboard` and a switch,
# not on its own. The dev server (`bun run dev`, port 7777) keeps working
# alongside: the installed one listens on 7778.
#
# Each is an app of its own, by its id: its windows' app_id, its desktop
# entry and its Electron profile, so the installed one and the dev one tell
# apart in launchers, in window rules and in notifications. Each has a
# hostname of its own too, as when they were Chromium apps, so their pages
# keep their origins (and what the pages stored): Chromium resolves any
# *.localhost to loopback and treats it as secure, so the bridges stay bound
# to 127.0.0.1.
{ self, inputs, lib, ... }:
let
  apps = {
    corkboard = { name = "corkboard"; url = "http://corkboard.localhost:7778/"; };
    corkboard-dev = { name = "corkboard (dev)"; url = "http://dev.corkboard.localhost:7777/"; };
    # The day plan's window (?view=plan) on the installed bridge, as an app
    # of its own: in the launcher, on Mod+P (niri.nix), with its own app_id.
    day-plan = { name = "Day plan"; url = "http://corkboard.localhost:7778/?view=plan"; };
  };
in
{
  # Each app's id (its windows' app_id) by its bridge's port, which is what a
  # Claude session in corkboard carries (CORKBOARD_PORT): claude-status
  # raises its window by it.
  flake.lib.corkboardAppIds = {
    "7778" = "corkboard";
    "7777" = "corkboard-dev";
  };

  flake.modules.homeManager.corkboard = { pkgs, lib, config, ... }:
    let
      port = 7778;
      bridge = inputs.corkboard.packages.${pkgs.stdenv.hostPlatform.system}.default;
      app = inputs.corkboard.packages.${pkgs.stdenv.hostPlatform.system}.app;

      # The stylix theme, as a Neovim plugin the bridge puts on the
      # runtimepath. Neovim's colors are corkboard's colors: the canvas draws
      # them, and the HTML panels take their background, text and accents
      # from them (push_theme in corkboard/init.lua), so a base16 colorscheme
      # built from stylix's palette themes all of it. The font goes the same
      # way, through vim.g.corkboard_font.
      stylixTheme =
        let
          c = config.lib.stylix.colors.withHashtag;
          palette = lib.concatMapStringsSep ", "
            (n: ''${n} = "${c.${n}}"'')
            (map (i: "base0${i}") [ "0" "1" "2" "3" "4" "5" "6" "7" "8" "9" "A" "B" "C" "D" "E" "F" ]);
        in
        pkgs.writeTextDir "plugin/corkboard-stylix.lua" ''
          vim.o.termguicolors = true
          require("mini.base16").setup({ palette = { ${palette} } })
          vim.g.colors_name = "stylix"
          vim.g.corkboard_font = {
            family = "${config.stylix.fonts.monospace.name}",
            size = ${toString config.stylix.fonts.sizes.terminal},
          }
        '';

      # Projects on other machines, opened over ssh: the bridge copies
      # remoteNvim there with `nix copy` and runs it in place of a local
      # Neovim, so files, consoles, Claude and the board are all on that
      # machine while the window stays here. The far side needs Nix with
      # this user trusted (to accept unsigned store paths) and nothing else
      # -- no rebuild of it, no Neovim installed.
      #
      # brain-vm's address comes from the same plan its launcher and
      # firewall use, and its ssh options are brain-vm-ssh's (host.nix): the
      # guest is rebuilt from scratch often enough that pinning its host key
      # buys nothing. BatchMode because the bridge is a service: a key the
      # agent does not hold has to fail, not wait on a prompt nobody sees.
      remotes = pkgs.writeText "corkboard-remotes.json" (builtins.toJSON {
        brain-vm = {
          target = "claude@${self.lib.agentVm.instances.brain-vm.guestAddress}";
          options = [
            "-o" "StrictHostKeyChecking=no"
            "-o" "UserKnownHostsFile=/dev/null"
            "-o" "GlobalKnownHostsFile=/dev/null"
            "-o" "LogLevel=ERROR"
            "-o" "BatchMode=yes"
            "-o" "ConnectTimeout=10"
          ];
        };
      });

      # The Neovim a remote runs: this machine's Neovim, plugins and theme,
      # with rg and fd for the pickers, as one store path to copy.
      #
      # Open project scans home for repos, and brain-vm keeps its checkouts
      # in /var/lib/second-brain/work rather than under /home/claude, so it
      # scans there too. On every remote, since brain-vm is the only one; fd
      # skips a directory that is not there.
      remoteNvim = pkgs.writeShellScript "corkboard-nvim" ''
        export PATH=${lib.makeBinPath [ pkgs.ripgrep pkgs.fd ]}:$PATH
        exec ${lib.getExe pkgs.neovim} \
          --cmd "let g:corkboard_project_dirs = ['~', '/var/lib/second-brain/work']" \
          --cmd "set rtp^=${lib.concatStringsSep "," [
          inputs.corkboard.packages.${pkgs.stdenv.hostPlatform.system}.plugin
          pkgs.vimPlugins.snacks-nvim
          pkgs.vimPlugins.mini-base16
          stylixTheme
        ]}" "$@"
      '';

      # `corkboard [--host NAME] [dir]`: Neovim opened in dir, or without one
      # in the last project opened (the bridge remembers it). With --host,
      # on that machine (see remotes), where dir is that machine's path.
      # corkboard-dev is the same against the dev bridge, and opens the
      # checkout itself when given no dir.
      #
      # Each opens a window of its app on its bridge, with a query (a dir, a
      # host) when given one; an app already running opens it as another
      # window of its own.
      mkLauncher = { name, service, defaultDir ? null }: pkgs.writeShellApplication {
        inherit name;
        runtimeInputs = [ pkgs.coreutils pkgs.jq pkgs.systemd ];
        text = ''
          # Started on demand too, so the first launch after a login does not
          # race the service coming up.
          systemctl --user start ${service}.service
          ${lib.optionalString (defaultDir != null) ''
            if [ $# -eq 0 ]; then set -- ${lib.escapeShellArg defaultDir}; fi
          ''}
          params=()
          if [ "''${1:-}" = "--host" ]; then
            params+=("host=$(jq -rn --arg v "$2" '$v | @uri')")
            shift 2
            [ $# -gt 0 ] && params+=("cwd=$(jq -rn --arg v "$1" '$v | @uri')")
          elif [ $# -gt 0 ]; then
            params+=("cwd=$(realpath -- "$1" | jq -Rr '@uri')")
          fi
          query=""
          [ ''${#params[@]} -gt 0 ] && query="?$(IFS='&'; echo "''${params[*]}")"
          exec ${lib.getExe app} --name ${name} --title ${lib.escapeShellArg apps.${name}.name} \
            ${lib.escapeShellArg apps.${name}.url}"$query"
        '';
      };

      # The bridge's environment, for the installed one and the dev one.
      bridgeEnv = { name, port, plugins, path }: [
        # Loopback only: whoever reaches the socket can run code as matthew.
        "CORKBOARD_HOST=127.0.0.1"
        "CORKBOARD_PORT=${toString port}"
        "CORKBOARD_NAME=${apps.${name}.name}"
        "CORKBOARD_PLUGINS=${lib.concatStringsSep ":" plugins}"
        "CORKBOARD_REMOTES=${remotes}"
        "CORKBOARD_REMOTE_NVIM=${remoteNvim}"
        # A user unit gets almost no PATH, and the Neovim it spawns runs
        # :terminal, LSPs and git, so it gets the login profile's.
        "PATH=${lib.concatStringsSep ":" ([
          "/run/wrappers/bin"
          "${config.home.profileDirectory}/bin"
          "/run/current-system/sw/bin"
        ] ++ path)}"
      ];

      # The dev bridge runs the checkout as it is on disk, on the port
      # `bun run dev` and the Vite dev server expect. Lua changes show on a
      # page reload (every page gets a new Neovim); page and bridge changes
      # on `systemctl --user restart corkboard-dev`, which rebuilds web/dist.
      # It needs the checkout's node_modules (`bun install` there).
      devDir = "${config.home.homeDirectory}/corkboard";
      devPort = 7777;
    in
    {
      home.packages = [
        (mkLauncher { name = "corkboard"; service = "corkboard"; })
        (mkLauncher { name = "corkboard-dev"; service = "corkboard-dev"; defaultDir = devDir; })
        # One window: launching it again brings that one forward (--one).
        (pkgs.writeShellApplication {
          name = "day-plan";
          runtimeInputs = [ pkgs.systemd ];
          text = ''
            systemctl --user start corkboard.service
            exec ${lib.getExe app} --name day-plan --title ${lib.escapeShellArg apps.day-plan.name} --one \
              ${lib.escapeShellArg apps.day-plan.url}
          '';
        })
      ];

      xdg.desktopEntries.day-plan = {
        name = "Day plan";
        genericName = "Planner";
        comment = "Today's plan, with Pepper beside it";
        exec = "day-plan";
        icon = "${app}/share/icons/hicolor/scalable/apps/corkboard.svg";
        categories = [ "Office" ];
        settings.StartupWMClass = "day-plan";
      };

      xdg.desktopEntries.corkboard = {
        name = "corkboard";
        genericName = "Editor";
        comment = "Neovim with the board and agent panels";
        exec = "corkboard %f";
        icon = "${app}/share/icons/hicolor/scalable/apps/corkboard.svg";
        categories = [ "Development" "TextEditor" ];
        settings.StartupWMClass = "corkboard";
      };

      xdg.desktopEntries.corkboard-dev = {
        name = "corkboard (dev)";
        genericName = "Editor";
        comment = "corkboard from ~/corkboard, on the corkboard project";
        exec = "corkboard-dev";
        icon = "${app}/share/icons/hicolor/scalable/apps/corkboard.svg";
        categories = [ "Development" "TextEditor" ];
        settings.StartupWMClass = "corkboard-dev";
      };

      # brain-vm's projects; the window opens wherever its login lands
      # (/opt/second-brain), and Open project lists the rest of them.
      xdg.desktopEntries.corkboard-brain-vm = {
        name = "corkboard (brain-vm)";
        genericName = "Editor";
        comment = "corkboard on the second brain VM, over ssh";
        exec = "corkboard --host brain-vm";
        icon = "${app}/share/icons/hicolor/scalable/apps/corkboard.svg";
        categories = [ "Development" "TextEditor" ];
      };

      systemd.user.services.corkboard = {
        Unit.Description = "corkboard bridge: browser websocket to nvim --embed";
        Service = {
          ExecStart = lib.getExe bridge;
          # The bridge's wrapper adds snacks.nvim after these plugins, and
          # its own nvim, rg and fd after this PATH.
          Environment = bridgeEnv {
            name = "corkboard";
            inherit port;
            plugins = [ pkgs.vimPlugins.mini-base16 stylixTheme ];
            path = [ ];
          };
          Restart = "on-failure";
          RestartSec = 2;
        };
        Install.WantedBy = [ "default.target" ];
      };

      # The work brain's vault into its memory in corkboard's Worker, every
      # 15 minutes, as the bridge (its sign-in). One way until the vault is a
      # mirror of the memory (~/corkboard/.agent/plans/memory.md, step 5); a
      # run that finds nothing changed changes nothing.
      systemd.user.services.corkboard-memory-sync = {
        Unit.Description = "corkboard: the work brain's vault into its memory";
        Service = {
          Type = "oneshot";
          ExecStart = "${bridge}/bin/corkboard-memory-sync work /home/matthew/second-brain/vault";
        };
      };
      systemd.user.timers.corkboard-memory-sync = {
        Unit.Description = "corkboard: sync the work brain's vault every 15 minutes";
        Timer = {
          OnBootSec = "2min";
          OnUnitActiveSec = "15min";
        };
        Install.WantedBy = [ "timers.target" ];
      };

      # Started by corkboard-dev, not at login.
      systemd.user.services.corkboard-dev = {
        Unit.Description = "corkboard dev bridge, from ~/corkboard";
        Service = {
          WorkingDirectory = devDir;
          ExecStart = "${lib.getExe pkgs.bun} run dev";
          # What the installed bridge's wrapper would add.
          Environment = bridgeEnv {
            name = "corkboard-dev";
            port = devPort;
            plugins = [ pkgs.vimPlugins.mini-base16 stylixTheme pkgs.vimPlugins.snacks-nvim ];
            path = [ (lib.makeBinPath [ pkgs.bun pkgs.neovim pkgs.ripgrep pkgs.fd ]) ];
          };
          Restart = "on-failure";
          RestartSec = 2;
        };
      };
    };

  # This host only, like claude-desktop: the input is a path on this
  # machine, so a host without ~/corkboard could not build it.
  flake.modules.nixos.corkboard = {
    home-manager.users.matthew.imports = [ self.modules.homeManager.corkboard ];
  };
}
