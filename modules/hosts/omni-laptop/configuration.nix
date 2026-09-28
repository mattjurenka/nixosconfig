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

    # Xiaomi Mi USB Receiver Mouse: 1200 DPI in hardware, scaled down to
    # my.mouse.targetDpi (800) so it matches every other mouse.
    my.mouse.hardwareDpi = 1200;

    # Isolated browser VM: tap device, host-side firewall and the read-only
    # drop box it shares. The VM itself is nixosConfigurations.claude-vm.
    my.claudeVm.enable = true;

    #locales
    time.timeZone = "America/Phoenix";
    i18n.defaultLocale = "en_US.UTF-8";
    
    # Configure network connections interactively with nmcli or nmtui.
    networking = {
      networkmanager.enable = true;
      # NetworkManager resets Wi-Fi power saving on every connect, so re-apply
      # the charger-based setting (see ac-power-switch below).
      networkmanager.dispatcherScripts = [{
        source = pkgs.writeShellScript "ac-power-switch-on-connect" ''
          [ "$2" = "up" ] && ${pkgs.systemd}/bin/systemctl start --no-block ac-power-switch.service
          exit 0
        '';
      }];
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
    # For CS2: renders at a lower res inside a native-res fullscreen window,
    # and owns mouse input so XWayland pointer warping doesn't fight the aim.
    programs.gamescope.enable = true;
    # Launch with `gamemoderun` to switch to performance power settings while in-game.
    programs.gamemode.enable = true;
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

    # On charger: performance profile + Wi-Fi power saving off (it adds ping spikes).
    # On battery: balanced profile + Wi-Fi power saving on.
    systemd.services.ac-power-switch = {
      description = "Switch power profile and Wi-Fi power saving on charger state";
      after = [ "power-profiles-daemon.service" ];
      wants = [ "power-profiles-daemon.service" ];
      wantedBy = [ "multi-user.target" ];
      path = [ config.services.power-profiles-daemon.package pkgs.iw ];
      serviceConfig.Type = "oneshot";
      script = ''
        if [ "$(cat /sys/class/power_supply/ACAD/online)" = 1 ]; then
          profile=performance; wifi_ps=off
        else
          profile=balanced; wifi_ps=on
        fi
        powerprofilesctl set "$profile"
        for dev in /sys/class/net/*/wireless; do
          [ -e "$dev" ] || continue
          iw dev "$(basename "$(dirname "$dev")")" set power_save "$wifi_ps" || true
        done
      '';
    };
    services.udev.extraRules = ''
      SUBSYSTEM=="power_supply", KERNEL=="ACAD", RUN+="${pkgs.systemd}/bin/systemctl start --no-block ac-power-switch.service"
    '';
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
