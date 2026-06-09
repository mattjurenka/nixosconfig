{ self, inputs, ... }: {
  perSystem = { pkgs, system, ... }: { # Add 'system' here to pull the correct binary architecture
    packages.myNoctalia = inputs.wrapper-modules.wrappers.noctalia-shell.wrap {
      inherit pkgs; 

      # Directly reference the compiled v5 binary from your new flake input
      package = inputs.noctalia.packages.${system}.default;

      # Parse your v5 settings file
      settings = (builtins.fromTOML 
        (builtins.readFile ./noctalia-config.toml));
    };
  };
}
