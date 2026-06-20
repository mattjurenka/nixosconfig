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
        log = {
          loglevel = "warning";
        };
        inbounds = [
          {
            # This opens a local SOCKS proxy on your machine
            listen = "127.0.0.1";
            port = 10808;
            protocol = "socks";
            settings = {
              udp = true;
            };
          }
          {
            # This opens a local HTTP proxy on your machine
            listen = "127.0.0.1";
            port = 10809;
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
                  #address = "18.140.57.219";
                  port = 443;
                  users = [
                    {
                      id = "17fa067b-c5ba-45d9-ab49-88b0c479634c";
                      #id = "9fcb4cba-3efa-4b7f-a79e-3a675778b471";
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
                fingerprint = "chrome"; # Mimics Chrome TLS fingerprint
                serverName = "www.microsoft.com";
                publicKey = "rOpqPdA0Bs_UQz68vFWfvxqFm96AuTu1JbsfnCQLRFM";
                #publicKey = "wQuKrA7d0BtWFvEjy5s8fqBY_pKBoaT2y5Is9YPdiDM";
                shortId = "0123456789abcdef";
              };
            };
            tag = "proxy";
          }
          {
            protocol = "freedom";
            tag = "direct";
          }
        ];
        # Optional routing rules so local traffic bypasses the proxy
        routing = {
          domainStrategy = "IPIfNonMatch";
          rules = [
            {
              type = "field";
              ip = [ "geoip:private" ];
              outboundTag = "direct";
            }
          ];
        };
      };
    };

    system.stateVersion = "26.11";

  };

}
