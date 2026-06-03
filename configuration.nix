# Edit this configuration file to define what should be installed on
# your system. Help is available in the configuration.nix(5) man page, on
# https://search.nixos.org/options and in the NixOS manual (`nixos-help`).

{ config, lib, pkgs, ... }:

{
  nix = {
    package = pkgs.nix;
    settings.experimental-features = [ "nix-command" "flakes" ];
  };

  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
    ];
  
  nixpkgs.config.allowUnfree = true;

  # Use the systemd-boot EFI boot loader.
  boot.loader = {
    grub = {
      enable = true;
      version = 2;
      device = "nodev";
      efiSupport = true;
    };
    efi = {
      canTouchEfiVariables = true;
      efiSysMountPoint = "/boot";
    };
  };

  # Configure network connections interactively with nmcli or nmtui.
  networking = {
    networkmanager.enable = true;
    hostName = "jurenka-laptop";
  };

  #QEMU-specific
  services.spice-vdagentd.enable = true;
  services.qemuGuest.enable = true;
  
  # Yubikey
  services.pcscd.enable = true;
  
  #locales
  time.timeZone = "China/Shanghai";
  i18n.defaultLocale = "en_US.UTF-8";

  #wayland-related
  security.polkit.enable = true;
  hardware.opengl.enable = true;

  users.users = {
    matthew = {
      createHome = true;
      isNormalUser = true;
      extraGroups = [
        "wheel"
      ];
    };
    root = {
      extraGroups = [ "wheel" ];
    };
  };

  environment.systemPackages = with pkgs; [
    git
    git-credential-manager

    curl
    wget
    vim
    htop
    chromium
  ];
  
  programs.git.config.credential = {
    helper = "manager";
    "https://github.com".username = "mattjurenka";
    credentialStore = "cache";
  };

  # This option defines the first version of NixOS you have installed on this particular machine,
  # and is used to maintain compatibility with application data (e.g. databases) created on older NixOS versions.
  #
  # Most users should NEVER change this value after the initial install, for any reason,
  # even if you've upgraded your system to a new NixOS release.
  #
  # This value does NOT affect the Nixpkgs version your packages and OS are pulled from,
  # so changing it will NOT upgrade your system - see https://nixos.org/manual/nixos/stable/#sec-upgrading for how
  # to actually do that.
  #
  # This value being lower than the current NixOS release does NOT mean your system is
  # out of date, out of support, or vulnerable.
  #
  # Do NOT change this value unless you have manually inspected all the changes it would make to your configuration,
  # and migrated your data accordingly.
  #
  # For more information, see `man configuration.nix` or https://nixos.org/manual/nixos/stable/options#opt-system.stateVersion .
  system.stateVersion = "25.11"; # Did you read the comment?

}

