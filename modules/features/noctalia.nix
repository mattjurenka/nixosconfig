# modules/features/noctalia.nix
{ inputs, ... }:
{
  # Every file in the dendritic pattern is strictly a top-level flake-parts module.
  # We use flake.modules.<class>.<feature> to house our config.
  
  config.flake.modules.homeManager.noctalia = { ... }: {

    # 1. IMPORT the external home-manager module exactly here
    imports = [
      inputs.noctalia.homeModules.default 
      # ^ Adjust this path based on what the upstream flake names its HM module
    ];

    # 2. DEFINE and configure the program now that the option is imported
    programs.noctalia = {
      enable = true;
      settings = builtins.fromTOML (builtins.readFile ./noctalia-config.toml);
    };
  };
}

