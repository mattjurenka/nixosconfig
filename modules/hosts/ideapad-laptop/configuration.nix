{ self, ... }: {
  flake.modules.nixos.ideapadLaptopConfiguration = { pkgs, ... }: {
    imports = [ self.modules.nixos.ideapadLaptopHardware ];

    # GRUB in EFI mode rather than systemd-boot, which is what the other two
    # hosts use: this disk was installed with it and there is nothing to gain
    # from converting it.
    boot.loader = {
      grub = {
        enable = true;
        device = "nodev";
        efiSupport = true;
      };
      efi = {
        canTouchEfiVariables = true;
        efiSysMountPoint = "/boot";
      };
    };

    # On top of the `hardware.graphics` base in workstation.nix: 32-bit GLU for
    # the Steam runtime on this machine.
    hardware.graphics.extraPackages32 = with pkgs.pkgsi686Linux; [
      libGLU
    ];

    # Pointer motion is normalised to my.mouse.targetDpi (800 by default).
    # Set this to the real DPI of the mouse used on this host, read off its
    # spec sheet or its configuration software.
    # my.mouse.hardwareDpi = 1200;

    networking.hostName = "jurenka-laptop";

    system.stateVersion = "26.11";
  };
}
