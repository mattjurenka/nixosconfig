{ self, inputs, ... }: {
  flake.nixosModules.vinkieDesktopConfiguration = { pkgs, lib, config, ... }: 
  let
    # Pull the compiled binary straight out of the flake inputs
    noctaliaGreeterPkg = inputs.noctalia-greeter.packages.${pkgs.stdenv.hostPlatform.system}.default;
  in
  {
    imports = [
      self.nixosModules.vinkieDesktopHardware
      inputs.noctalia-greeter.nixosModules.default
    ];
    home-manager.users.matthew = self.homeModules.matthewModule;

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

    nixpkgs.config.allowUnfree = true;

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

    hardware.graphics = {
      enable = true;
      enable32Bit = true;
      extraPackages = with pkgs; [
        nvidia-vaapi-driver
      ];
    };

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

    #locales
    time.timeZone = "America/Phoenix";
    i18n.defaultLocale = "en_US.UTF-8";
    
    # Configure network connections interactively with nmcli or nmtui.
    networking = {
      networkmanager.enable = true;
      hostName = "vinkie-desktop";
    };

    #QEMU-specific
    services.spice-vdagentd.enable = true;
    services.qemuGuest.enable = true;
   
    environment.systemPackages = with pkgs; [
      vim
      gimp
      git
      zip
      unzip
      btop
      android-tools
      wget
      upower
      libGLU
    ];

    programs.steam = {
      enable = true;
    };
    programs.steam.package = pkgs.steam.override {
      extraPkgs = pkgs': with pkgs'; [
        libGLU
      ];
    };

    fonts.packages = with pkgs; [
      nerd-fonts.jetbrains-mono
      noto-fonts
      noto-fonts-cjk-sans
      noto-fonts-cjk-serif
      noto-fonts-color-emoji
      twemoji-color-font
    ];

    fonts.fontconfig.defaultFonts = {
      monospace = [ "JetBrainsMono NF" ];
    };

    services.upower.enable = true;

    # XRAY proxy
    # networking.proxy.default = "http://127.0.0.1:10809";
    # USDB https proxy
    # networking.proxy.default = "http://172.19.252.11:8080";
    networking.proxy.noProxy = "127.0.0.1,localhost";

    users.users = {
      matthew = {
        createHome = true;
        isNormalUser = true;
        extraGroups = [
          "wheel"
          "video"
          "render"
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

    services.power-profiles-daemon.enable = true;
    hardware.bluetooth = {
      enable = true;
      powerOnBoot = true;
      settings = {
        General = {
          # Enables A2DP Sink, Media, and lower-level profiles
          Enable = "Source,Sink,Media,Socket";
          # Speeds up connection handshakes 
          FastConnectable = true;
          # Keeps battery status updating accurately in Noctalia
          Experimental = true;
          AutoConnect = true;
          JustWorksRepairing = "always";
        };
        Policy = {
          AutoEnable = true;
        };
      };
    };
    
    # Ensure the Pipewire Bluetooth audio backend is enabled
    services.pipewire = {
      enable = true;
      alsa.enable = true;
      pulse.enable = true;
      wireplumber.enable = true;
    };

    programs.nix-ld.enable = true;
    programs.nix-ld.libraries = with pkgs; [
      stdenv.cc.cc
      openssl
      zlib
      # Bun specific dependencies if needed, though cc and openssl usually cover it
    ];

    system.stateVersion = "26.11";

  };

}
