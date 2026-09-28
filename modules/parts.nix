{ lib, flake-parts-lib, inputs, ... }: {
  imports = [
    # adds home-manager options to flake-parts
    inputs.home-manager.flakeModules.home-manager
  ];

  # flake.lib is not a flake-parts output by default, so without a declaration
  # here only one module could ever define a key under it.
  options.flake = flake-parts-lib.mkSubmoduleOptions {
    lib = lib.mkOption {
      type = lib.types.lazyAttrsOf lib.types.raw;
      default = { };
      description = "Helpers and constants shared between the modules in this tree.";
    };
  };

  config = {
    systems = [
      "x86_64-linux"
      "x86_64-darwin"
      "aarch64-linux"
      "aarch64-darwin"
    ];
  };
}
