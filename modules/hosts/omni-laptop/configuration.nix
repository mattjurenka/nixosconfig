{ self, inputs, ... }: {
  flake.nixosModules.omniLaptopConfiguration = { pkgs, lib, config, ... }: 
  let
    # Pull the compiled binary straight out of the flake inputs
    noctaliaGreeterPkg = inputs.noctalia-greeter.packages.${pkgs.stdenv.hostPlatform.system}.default;
  in
  {
    imports = [
      self.nixosModules.omniLaptopHardware
      inputs.noctalia-greeter.nixosModules.default
    ];
    home-manager.users.matthew = self.homeModules.matthewModule;

    # Use the systemd-boot EFI boot loader.
    boot.loader = {
      systemd-boot = {
        enable = true;
      };
      efi = {
        canTouchEfiVariables = true;
        efiSysMountPoint = "/boot";
      };
    };

    nixpkgs.config.allowUnfree = true;

    # Radeon 840M integrated graphics (AMD Ryzen AI 7 445) - handled by mesa/amdgpu.
    hardware.graphics = {
      enable = true;
      enable32Bit = true;
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
      hostName = "omni-laptop";
    };

    #QEMU-specific
    services.spice-vdagentd.enable = true;
    services.qemuGuest.enable = true;
   
    environment.systemPackages = with pkgs; [
      vim
      (gimp-with-plugins.override { plugins = with gimpPlugins; [ gmic ]; })
      gmic
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

    system.stateVersion = "26.05";

  };

}
