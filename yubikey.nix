{ config, pkgs, ... }:

{
  # User-specific packages
  home.packages = with pkgs; [
    yubikey-manager
    yubikey-personalization
  ];

  # Configure GnuPG inside Home Manager
  programs.gpg = {
    enable = true;
    # Optional: Automatically discover the Yubikey on card inserts
    scdaemonSettings = {
      disable-ccid = false;
    };
  };

  # Enable the user-level GPG Agent with SSH support
  services.gpg-agent = {
    enable = true;
    enableSshSupport = true;
    # Keep the agent alive for caching keys if desired
    defaultCacheTtl = 600;
    maxCacheTtl = 7200;
  };
}
