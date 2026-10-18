# A machine Matt sits at: the shape every one of his desktops and laptops has
# in common, so that a host file is left saying only what is true about that
# machine.
#
# This was three copies of the same ~150 lines in
# modules/hosts/{omni-laptop,ideapad-laptop,vinkie-desktop}/configuration.nix
# -- same timezone, same locale, same user, same fonts, same greeter, same
# Steam override, same bluetooth settings down to the comments. 37 option
# paths were set identically in all three. A host is now its hardware, its
# name, its state version and whatever is genuinely its own.
#
# The capabilities are separate files rather than inlined here, because each
# one is a thing a future host might want without the rest; this aspect is the
# composition, which is the Inheritance Aspect in the dendritic pattern.
{ self, inputs, ... }: {
  flake.modules.nixos.workstation = { pkgs, ... }: {
    imports = [
      # Capabilities, each in its own feature file.
      self.modules.nixos.audio
      self.modules.nixos.bluetooth
      self.modules.nixos.fonts
      self.modules.nixos.login
      self.modules.nixos.gaming
      self.modules.nixos.power

      # The rest of the desktop, which every one of these hosts imported from
      # its own default.nix before this file existed. niri brings my.mouse
      # with it; stylix needs its own input module alongside the aspect that
      # configures it, and noctaliaGreeterAppearance themes the greeter in
      # login.nix.
      self.modules.nixos.onepassword
      self.modules.nixos.niri
      self.modules.nixos.myHomeManager
      inputs.stylix.nixosModules.stylix
      self.modules.nixos.stylix
      self.modules.nixos.noctaliaGreeterAppearance
    ];

    # One home for one person, shared by every host rather than written per
    # host; anything genuinely host-specific belongs in a feature module that
    # only that host imports. See modules/features/matthew-home.nix.
    home-manager.users.matthew = self.modules.homeManager.matthewModule;

    nixpkgs.config.allowUnfree = true;

    # The base of it. A host with a discrete GPU or a 32-bit quirk adds its
    # own `extraPackages`/`extraPackages32` on top; these two lines are what
    # every one of them wanted.
    hardware.graphics = {
      enable = true;
      enable32Bit = true;
    };

    #locales
    time.timeZone = "America/Phoenix";
    i18n.defaultLocale = "en_US.UTF-8";

    # Configure network connections interactively with nmcli or nmtui. The
    # host supplies its own `networking.hostName`.
    networking.networkmanager.enable = true;

    # XRAY proxy
    # networking.proxy.default = "http://127.0.0.1:10809";
    # USDB https proxy
    # networking.proxy.default = "http://172.19.252.11:8080";
    networking.proxy.noProxy = "127.0.0.1,localhost";

    # Carried over from when these configurations were written against a VM and
    # kept because all three hosts had them: harmless on bare metal, and the
    # agent in it is what makes a guest resize its console and share a
    # clipboard if one of these ever runs as one.
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

    # For binaries that expect an FHS: bun, anything downloaded rather than
    # packaged, and the language servers an editor fetches for itself.
    programs.nix-ld.enable = true;
    programs.nix-ld.libraries = with pkgs; [
      stdenv.cc.cc
      openssl
      zlib
      # Bun specific dependencies if needed, though cc and openssl usually cover it
    ];
  };
}
