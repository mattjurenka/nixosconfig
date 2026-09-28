{ ... }: {
  flake.nixosModules.onepassword = { lib, config, ... }:
    let
      cfg = config.my.onepassword;
    in
    {
      options.my.onepassword = {
        users = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ "matthew" ];
          description = ''
            Users allowed to authorise 1Password's privileged helpers via
            polkit: unlocking with the system login/fingerprint, and the
            browser integration, which checks the calling browser against
            this list before it will talk to the desktop app.
          '';
        };
      };

      config = {
        # The CLI, and the `op` <-> desktop app handshake that lets `op` unlock
        # from the already-unlocked GUI instead of re-prompting for the
        # password.
        programs._1password.enable = true;

        programs._1password-gui = {
          enable = true;
          polkitPolicyOwners = cfg.users;
        };
      };
    };
}
