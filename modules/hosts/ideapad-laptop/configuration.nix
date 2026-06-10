{ self, inputs, ... }: {
  flake.nixosModules.ideapadLaptopConfiguration = { pkgs, lib, ... }: {
    imports = [
      self.nixosModules.ideapadLaptopHardware
    ];
    home-manager.users.matthew = self.homeModules.matthewModule;

    # Use the systemd-boot EFI boot loader.
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

    nixpkgs.config.allowUnfree = true;

    hardware.graphics.enable = true;

    services.displayManager.sddm = {
      enable = true;
      wayland.enable = true;
    };

    #locales
    time.timeZone = "Asia/Shanghai";
    i18n.defaultLocale = "en_US.UTF-8";
    
    # Configure network connections interactively with nmcli or nmtui.
    networking = {
      networkmanager.enable = true;
      hostName = "jurenka-laptop";
    };

    #QEMU-specific
    services.spice-vdagentd.enable = true;
    services.qemuGuest.enable = true;
   
    environment.systemPackages = with pkgs; [
      vim
      chromium
      gimp
      git
      zip
      unzip
      telegram-desktop
      btop
      android-tools
      wget
      upower
    ];

    services.upower.enable = true;

    networking.proxy.default = "http://10.140.27.149:8080";
    networking.proxy.noProxy = "127.0.0.1,localhost";

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

    nix.settings.experimental-features = [ "nix-command" "flakes" ];

    programs.git = {
      enable = true;
      
      # Set your default global identity configurations
      config = {
        user = {
          name = "Matt Jurenka";
          email = "matt.jurenka@comcast.net";
        };
        
        # Optional but highly recommended helper settings:
        init = {
          defaultBranch = "main";
        };
      };
    };

  };
}
