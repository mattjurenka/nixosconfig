# The greeter: what is on screen between boot and a session.
#
# greetd with noctalia's own greeter, so the login screen is drawn by the same
# shell as the desktop behind it -- and themed by the same palette, which is
# what `noctaliaGreeterAppearance` in noctalia.nix generates.
#
# The greeter runs as its own `greeter` user rather than as Matt: it is a
# session that exists before anyone has proven who they are.
{ inputs, ... }: {
  flake.modules.nixos.login = {
    imports = [ inputs.noctalia-greeter.nixosModules.default ];

    services.greetd = {
      enable = true;
      settings = {
        default_session = {
          user = "greeter";
        };
      };
    };

    programs.noctalia-greeter = {
      enable = true;
    };
  };
}
