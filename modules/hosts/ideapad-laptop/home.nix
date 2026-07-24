{ self, inputs, config, ... }: 
{

  # This is your standalone home-manager configuration, meant to be used on non-nixos machines
  # with the home-manager command
  flake.homeConfigurations.matthew = inputs.home-manager.lib.homeManagerConfiguration {
    pkgs = import inputs.nixpkgs { system = "x86_64-linux"; };
    imports = [
      self.homeModules.matthewModule
      {
        home.username = "matthew";
        home.homeDirectory = "/home/matthew";
      }
    ];
  };

  # This is your home.nix, your module where you configure home-manager
  # It's imported both in standalone configuration above, and in your nixos configuration
  flake.homeModules.matthewModule = { pkgs, ... }: {
    imports = [
      config.flake.modules.homeManager.noctalia
      inputs.spicetify-nix.homeManagerModules.default
    ];

    programs.kitty.enable = true;
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
      ];
    };

    programs.obs-studio.enable = true;

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
    ];

    home.stateVersion = "24.11";
  };

}

#TODO:
# test out rust devshell
