{ self, inputs, config, ... }: {

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
    ];

    programs.kitty.enable = true;
    stylix.targets.kitty.enable = true;

    stylix.targets.vscode.enable = true;
    programs.vscode = {
      enable = true;
      
      extensions = with pkgs.vscode-extensions; [
        jnoortheen.nix-ide
      ];
      
      profiles.default.userSettings = {
        "nix.enableLanguageServer" = true;
        "nix.serverPath" = "nil";
      };
    };
  
    programs.bash.enable = true;
    programs.bash.shellAliases.ll = "ls -l";

    home.packages = with pkgs; [
      ripgrep
      gemini-cli
      zathura
      nil
      loupe
    ];
    home.stateVersion = "24.11";
  };

}
