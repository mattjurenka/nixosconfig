{ self, inputs, ... }: {

  # This is your module that imports and configures home-manager
  flake.modules.nixos.myHomeManager = { pkgs, ... }: {
    imports = [
      inputs.home-manager.nixosModules.default # import official home-manager NixOS module
    ];

    home-manager = {
      useGlobalPkgs = true;
      useUserPackages = true;

      # Activation refuses to overwrite a file it does not already own, and
      # stops the whole switch when it finds one. That is the right default --
      # silently destroying something hand-written would be worse -- but it
      # makes taking over a path that an application wrote for itself a
      # two-step job: switch, watch it fail, move the file, switch again.
      #
      # With this, the first activation renames the intruder to
      # <name>.hm-backup and carries on. It came up over
      # ~/.config/mimeapps.list, which Telegram and Claude Desktop had written
      # their own URL handlers into before mime-defaults.nix declared it, and
      # it will come up again: every app that registers itself on first run is
      # a candidate.
      backupFileExtension = "hm-backup";
    };
  };

}
