# The framework wiring, and the only file in this tree that is about flake-parts
# rather than about a machine.
#
# Two things used to live here separately, in modules/flake-modules.nix and
# modules/parts.nix; they were the same concern filed twice.
{ lib, flake-parts-lib, inputs, ... }:
{
  imports = [
    # `flake.modules.<class>.<name>`: the one namespace every aspect in this
    # tree is defined in, and the mechanism the dendritic pattern is built on.
    #
    # flake-parts has no option for that attribute by default, so it falls back
    # to "define it exactly once" -- which held only while noctalia.nix was the
    # single file using it. With this imported, every file can add to it and
    # the definitions merge.
    #
    # Everything used to be split: the NixOS aspects were
    # `flake.nixosModules.<name>` -- the legacy flake output -- and only the
    # Home Manager ones were here. They were unified on 2026-10-17, and what
    # that buys is in flake-parts' extras/modules.nix: every module under
    # `flake.modules.<class>` is wrapped with `_class = "<class>"` and a
    # `_file` of `<flake>#modules.<class>.<name>`. So a Home Manager aspect
    # imported into a NixOS host now fails as a class mismatch rather than as a
    # pile of unknown options, and an error names the aspect rather than the
    # file it happened to be written in. The legacy attribute carried neither.
    #
    # Aspects are referenced as `self.modules.<class>.<name>`; nothing in this
    # tree should define or read `flake.nixosModules` or `flake.homeModules`
    # again.
    inputs.flake-parts.flakeModules.modules

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
