{ self, ... }: {
  flake.modules.nixos.vinkieDesktopConfiguration = { pkgs, config, ... }: {
    imports = [ self.modules.nixos.vinkieDesktopHardware ];

    # Use the systemd-boot EFI boot loader.
    boot.loader = {
      systemd-boot = {
        enable = true;
        #device = "nodev";
        #efiSupport = true;
      };
      efi = {
        canTouchEfiVariables = true;
        efiSysMountPoint = "/boot";
      };
    };

    # The one host here with a discrete GPU.
    # Load NVIDIA driver for Xorg and Wayland
    services.xserver.videoDrivers = [ "nvidia" ];

    hardware.nvidia = {
      # Modesetting is required for Wayland / modern compositors
      modesetting.enable = true;

      # Set driver package (production, latest, stable, or beta)
      package = config.boot.kernelPackages.nvidiaPackages.stable;

      open = true;

      # Enable settings menu
      nvidiaSettings = true;
    };

    # On top of the `hardware.graphics` base in workstation.nix.
    hardware.graphics.extraPackages = with pkgs; [
      nvidia-vaapi-driver
    ];

    # Pointer motion is normalised to my.mouse.targetDpi (800 by default).
    # Set this to the real DPI of the mouse used on this host, read off its
    # spec sheet or its configuration software.
    # my.mouse.hardwareDpi = 1200;

    networking.hostName = "vinkie-desktop";

    system.stateVersion = "26.11";
  };
}
