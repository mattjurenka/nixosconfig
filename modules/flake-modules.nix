# Declares `flake.modules.<class>.<name>`, the shared namespace the feature
# files use for modules that are not whole flake outputs of their own.
#
# flake-parts has no option for that attribute by default, so it falls back to
# "define it exactly once" -- which held only while noctalia.nix was the single
# file using it. With this imported, every file can add to it and the
# definitions merge.
{ inputs, ... }:
{
  imports = [ inputs.flake-parts.flakeModules.modules ];
}
