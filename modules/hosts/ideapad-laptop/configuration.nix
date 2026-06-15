{ self, inputs, ... }: {
  flake.nixosModules.ideapadLaptopConfiguration = { pkgs, lib, ... }: 
  let
    # Pull the compiled binary straight out of the flake inputs
    noctaliaGreeterPkg = inputs.noctalia-greeter.packages.${pkgs.stdenv.hostPlatform.system}.default;
  in
  {
    imports = [
      self.nixosModules.ideapadLaptopHardware
      inputs.noctalia-greeter.nixosModules.default
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
      btop
      android-tools
      wget
      upower
    ];

    fonts.packages = with pkgs; [
      nerd-fonts.jetbrains-mono
    ];

    fonts.fontconfig.defaultFonts = {
      monospace = [ "JetBrainsMono NF" ];
    };

    services.upower.enable = true;

    networking.proxy.default = "http://127.0.0.1:10809";
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

    services.xray = {
      enable = true;
      settings = {
        log = { logLevel = "warning"; };
        inbounds = [
          {
            port = 10808;
            listen = "127.0.0.1";
            protocol = "socks";
            settings = { auth = "noauth"; udp = true; };
          }
          {
            port = 10809;
            listen = "127.0.0.1";
            protocol = "http";
          }
        ];
        outbounds = [
          {
            protocol = "vless";
            settings = {
              vnext = [
                {
                  address = "47.76.156.171";
                  port = 443;
                  users = [
                    {
                      id = "17fa067b-c5ba-45d9-ab49-88b0c479634c";
                      encryption = "none";
                      flow = "xtls-rprx-vision";
                    }
                  ];
                }
              ];
            };
            streamSettings = {
              network = "tcp";
              security = "reality";
              realitySettings = {
                show = false;
                fingerprint = "chrome";
                serverName = "www.microsoft.com";
                publicKey = "rOpqPdA0Bs_UQz68vFWfvxqFm96AuTu1JbsfnCQLRFM";
                shortId = "0123456789abcdef";
              };
            };
          }
        ];
      };
    };

    system.stateVersion = "26.11";

  };

}
