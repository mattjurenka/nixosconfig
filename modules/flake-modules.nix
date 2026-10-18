# Declares `flake.modules.<class>.<name>`: the one namespace every aspect in
# this tree is defined in, and the mechanism the dendritic pattern is built on.
#
# flake-parts has no option for that attribute by default, so it falls back to
# "define it exactly once" -- which held only while noctalia.nix was the single
# file using it. With this imported, every file can add to it and the
# definitions merge.
#
# Everything used to be split: the NixOS aspects were `flake.nixosModules.<name>`
# -- the legacy flake output -- and only the Home Manager ones were here. They
# were unified on 2026-10-17, and what that buys is in flake-parts'
# extras/modules.nix: every module under `flake.modules.<class>` is wrapped with
# `_class = "<class>"` and a `_file` of `<flake>#modules.<class>.<name>`. So a
# Home Manager aspect imported into a NixOS host now fails as a class mismatch
# rather than as a pile of unknown options, and an error names the aspect rather
# than the file it happened to be written in. The legacy attribute carried
# neither.
#
# Aspects are referenced as `self.modules.<class>.<name>`; nothing in this tree
# should define or read `flake.nixosModules` or `flake.homeModules` again.
{ inputs, ... }:
{
  imports = [ inputs.flake-parts.flakeModules.modules ];
}
