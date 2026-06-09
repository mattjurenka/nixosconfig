{ ... }:
{
  flake.nixosModules.user-matt = { pkgs, ... }: {
    users.users.matt = {
      isNormalUser = true;
      description = "Matthew Jurenka";
      extraGroups = [ "networkmanager" "wheel" ];
    };
  };
}
