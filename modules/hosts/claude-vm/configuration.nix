{ self, ... }: {
  # A throwaway desktop whose only job is to run Chromium with the Claude
  # extension. Nothing of this machine is reachable from inside it except the
  # read-only drop box at /mnt/dropbox; see modules/features/claude-vm-host.nix
  # for the half of the boundary that the guest cannot touch.
  flake.nixosModules.claudeVmConfiguration = { pkgs, lib, config, modulesPath, ... }:
    let
      vm = self.lib.claudeVm;
    in
    {
      imports = [ "${modulesPath}/virtualisation/qemu-vm.nix" ];

      nixpkgs.hostPlatform = "x86_64-linux";

      virtualisation = {
        # The guest builds its own store image from the closure instead of
        # mounting the host's /nix/store. No host path is mapped into the VM.
        useNixStoreImage = true;
        mountHostNixStore = false;
        writableStore = true;

        # Replaces the default set wholesale. Upstream also exports
        # $TMPDIR/xchg and $TMPDIR/shared read-write; dropping them leaves the
        # drop box as the only way in.
        sharedDirectories = lib.mkForce {
          dropbox = {
            source = vm.shareDir;
            target = "/mnt/dropbox";
            # virtiofsd gets --readonly. It runs on the host, so root in the
            # guest cannot remount this read-write.
            writable = false;
          };
        };

        diskImage = vm.diskImage;
        diskSize = 32768;
        memorySize = 8192;
        cores = 4;

        # Not "open a window": this only keeps upstream from passing
        # -nographic, which would drop the GPU and fight the explicit
        # -display/-serial pair below.
        graphics = true;

        # Replaces QEMU's user-mode networking, which would expose the host's
        # loopback to the guest as 10.0.2.2.
        qemu.networkingOptions = lib.mkForce [
          "-netdev tap,id=net0,ifname=${vm.interface},script=no,downscript=no"
          "-device virtio-net-pci,netdev=net0,mac=${vm.mac}"
        ];

        # Serial first, so the kernel and the login prompt come out in the
        # terminal that ran `claude-vm` rather than on the virtual screen.
        qemu.consoles = [ "tty0" "ttyS0,115200n8" ];

        qemu.options = [
          # The GPU still exists, it just has nowhere to draw until a viewer
          # attaches. egl-headless does the GL on the host's render node and
          # hands the result to SPICE; this is the pairing QEMU documents for
          # virgl without a local window.
          "-vga none"
          "-device virtio-vga-gl"
          "-display egl-headless,rendernode=/dev/dri/renderD128"

          # No window, no clipboard bridge, no agent file transfer: the drop
          # box stays the only way in. Local unix socket only, never a port.
          "-spice unix=on,addr=${vm.spiceSocket},disable-ticketing=on,disable-copy-paste=on,disable-agent-file-xfer=on"

          # The VM's console lands on the terminal's stdin/stdout. Ctrl-a c
          # switches to the QEMU monitor, Ctrl-a x kills the VM.
          "-serial mon:stdio"
        ];
      };

      networking = {
        hostName = "claude-vm";
        # Static, so the guest never needs DHCP from the host.
        usePredictableInterfaceNames = false;
        useDHCP = false;
        interfaces.eth0.ipv4.addresses = [
          {
            address = vm.guestAddress;
            prefixLength = vm.prefixLength;
          }
        ];
        defaultGateway = vm.hostAddress;
        # Public resolvers: the host drops everything addressed to itself, so
        # there is nothing to resolve against locally.
        nameservers = [ "1.1.1.1" "9.9.9.9" ];
        firewall.enable = true;
      };

      users.mutableUsers = false;
      users.users.claude = {
        isNormalUser = true;
        description = "Claude browser sandbox";
        # The VM is the security boundary, not this password; root in here
        # still cannot see the host.
        password = "claude";
        # seat: a login on the serial console gets no logind seat, so niri
        # cannot take the DRM device that way. seatd hands it over instead.
        extraGroups = [ "wheel" "video" "render" "seat" ];
      };

      # Boots to a shell on the serial console. No display manager, no
      # compositor until asked for.
      services.getty.autologinUser = "claude";

      services.seatd.enable = true;

      environment.sessionVariables.NIXOS_OZONE_WL = "1";

      # Force-installed by policy, so it is present on first boot and cannot be
      # removed from inside the browser.
      programs.chromium = {
        enable = true;
        extensions = [ "fcoeoabgfenejglbffodgkkbkcdhcgfn" ]; # Claude
      };

      # Chromium follows the compositor up and comes back if it is closed, so
      # `browser` is the only command needed to get a window.
      systemd.user.services.chromium = {
        description = "Chromium";
        partOf = [ "graphical-session.target" ];
        after = [ "graphical-session.target" ];
        wantedBy = [ "graphical-session.target" ];
        serviceConfig = {
          ExecStart = lib.getExe pkgs.chromium;
          Restart = "on-failure";
        };
      };

      environment.systemPackages = with pkgs; [
        chromium
        kitty
        yazi
        thunar
        vim

        (writeShellScriptBin "browser" ''
          set -eu

          if systemctl --user --quiet is-active niri.service 2>/dev/null; then
            echo "Compositor is already up."
          else
            # Detached, so the serial console stays usable while it runs.
            # Without a logind seat on this tty, libseat has to be pointed at
            # seatd explicitly rather than trying logind first.
            setsid --fork env LIBSEAT_BACKEND=seatd \
              ${config.programs.niri.package}/bin/niri-session \
              > "$HOME/niri-session.log" 2>&1
            echo "Compositor starting; see ~/niri-session.log if nothing appears."
          fi

          echo "Run 'claude-vm-view' on the host to see the screen."
        '')
      ];

      fonts.packages = with pkgs; [
        nerd-fonts.jetbrains-mono
        noto-fonts
        noto-fonts-cjk-sans
        noto-fonts-color-emoji
      ];

      fonts.fontconfig.defaultFonts.monospace = [ "JetBrainsMono NF" ];

      services.pipewire = {
        enable = true;
        alsa.enable = true;
        pulse.enable = true;
      };

      time.timeZone = "America/Phoenix";
      i18n.defaultLocale = "en_US.UTF-8";

      nix.settings.experimental-features = [ "nix-command" "flakes" ];

      system.stateVersion = "26.11";
    };
}
