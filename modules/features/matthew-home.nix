{ self, inputs, config, ... }: 
{

  # This is your standalone home-manager configuration, meant to be used on non-nixos machines
  # with the home-manager command
  flake.homeConfigurations.matthew = inputs.home-manager.lib.homeManagerConfiguration {
    pkgs = import inputs.nixpkgs { system = "x86_64-linux"; };
    modules = [
      self.modules.homeManager.matthewModule
      {
        home.username = "matthew";
        home.homeDirectory = "/home/matthew";
      }
    ];
  };

  # Every host's configuration.nix wires this same module into
  # home-manager.users.matthew, so it is shared across all of them rather than
  # being per-host. Anything genuinely host-specific belongs in a feature module
  # that only that host imports.
  flake.modules.homeManager.matthewModule = { pkgs, ... }: {
    imports = [
      config.flake.modules.homeManager.noctalia
      config.flake.modules.homeManager.claudeStatus
      # my.location, read by both halves of adaptive display: noctalia's night
      # light for colour temperature and the sun-following backlight curve for
      # brightness. Must come in alongside them, not instead of them.
      config.flake.modules.generic.location
      config.flake.modules.homeManager.adaptiveDisplay
      # Zed with Claude Code in its agent panel; see modules/features/zed.nix.
      config.flake.modules.homeManager.zed
      inputs.spicetify-nix.homeManagerModules.default
    ];

    programs.kitty = {
      enable = true;
      # kitten __watch_conf__ leaks memory; config is a read-only store symlink anyway
      settings.auto_reload_config = -1;
    };
    stylix.targets.kitty.enable = true;

    stylix.targets.vscode.enable = true;
    programs.vscode = {
      enable = true;
      
      profiles.default = {
        extensions = with pkgs.vscode-extensions; [
          jnoortheen.nix-ide
          vscodevim.vim
          ms-vscode-remote.remote-ssh
          ms-vscode.remote-explorer
          bradlc.vscode-tailwindcss
        ];

        userSettings = {
          "nix.enableLanguageServer" = true;
          "nix.serverPath" = "nil";
          "keyboard.dispatch" = "keyCode";
          # --- Remote SSH Network & Proxy Performance Optimizations ---
      
          # Force VS Code to download the server piece locally and SCP it over,
          # bypassing the cross-border pipe on the EC2 instance side.
          "remote.SSH.localServerDownload" = "off";
          
          # Use the stable classic connection architecture (bypasses node exec server hanging)
          "remote.SSH.useExecServer" = false;
          
          # Handle extensions locally to save bandwidth and compute on the remote target
          "remote.downloadExtensionsLocally" = true;
          
          # Give the handshake extra time over the VLESS loop before giving up
          "remote.SSH.connectTimeout" = 60;

          # Strip out heavy, continuous telemetry chatter over the proxy
          "telemetry.telemetryLevel" = "off";
          "workbench.settings.sync.enable" = false;

          # Kill aggressive cross-border file watching on target builds
          "files.watcherExclude" = {
            "**/.git/objects/**" = true;
            "**/.git/subtree-cache/**" = true;
            "**/node_modules/**" = true;
            "**/target/**" = true;
            "**/dist/**" = true;
          };

          # Streamline remote terminal persistence to save background state overhead
          "terminal.integrated.enablePersistentSessions" = false;
        };
      };
    };
  
    programs.bash.enable = true;
    programs.bash.shellAliases.ll = "ls -l";

    # Per-directory env vars (used to switch Claude Code's account/config dir
    # per repo via CLAUDE_CONFIG_DIR in each repo's .envrc).
    programs.direnv = {
      enable = true;
      nix-direnv.enable = true;
    };

    programs.spicetify.enable = true;

    programs.fastfetch = {
      enable = true;
    };

    programs.yazi = {
      enable = true;
      enableBashIntegration = true;
      shellWrapperName = "y";
    };

    programs.chromium = {
      enable = true;
      extensions = [
        { id = "bfnaelmomeimhlpmgjnjophhpkkoljpa"; } # Phantom
        { id = "fdjamakpfbbddfjaooikfcpapjohcfmg"; } # Dashlane
        { id = "aeblfdkhhhdcdjpifhhbdiojplfjncoa"; } # 1Password
        # Claude (fcoeoabgfenejglbffodgkkbkcdhcgfn) is deliberately absent: it
        # runs on the claude-vm host instead, so it only ever sees that
        # throwaway machine's browser.
      ];
    };

    programs.obs-studio = {
      enable = true;
      # Upstream OBS has no per-application audio capture on Linux, so its only
      # audio sources are the whole desktop sink and the mic. This plugin adds
      # an "Application Audio Capture (PipeWire)" source that pulls a single
      # program's stream off its PipeWire node, which is how a recording gets
      # game audio with no Discord or mic in it.
      plugins = [ pkgs.obs-studio-plugins.obs-pipewire-audio-capture ];
    };

    # Prism writes the absolute java path into each instance's config, so
    # selecting a raw /nix/store JDK breaks that instance as soon as a nixpkgs
    # bump rebuilds the JDK. These give each runtime a stable path that
    # activation re-points, and keep the JDKs alive as gcroots. Point an
    # instance at ~/.local/share/PrismLauncher/java/<n>/bin/java by hand rather
    # than using Prism's Auto-detect. Which version a pack needs: 8 for 1.12.2
    # and older, 17 for 1.18-1.20.4, 21 for 1.20.5+.
    home.file = {
      ".local/share/PrismLauncher/java/8".source = pkgs.jdk8;
      ".local/share/PrismLauncher/java/17".source = pkgs.jdk17;
      ".local/share/PrismLauncher/java/21".source = pkgs.jdk21;
    };

    home.packages = with pkgs; [
      ripgrep
      gemini-cli
      zathura
      nil
      loupe
      cmatrix
      discord
      telegram-desktop
      awscli2
      jq
      # Viewer for the second brain's vault at ~/second-brain/vault. Managed
      # here rather than run from the AppImage that was sitting in ~/Downloads,
      # which is exactly the drift a declarative system exists to avoid.
      obsidian
      vlc
      # Minecraft: the launcher fetches the game itself at runtime, and its
      # nixpkgs wrapper supplies the JDKs plus the GL/GLFW/OpenAL libraries the
      # game expects to find outside the store.
      prismlauncher
    ];

    home.stateVersion = "24.11";
  };

}

#TODO:
# test out rust devshell
